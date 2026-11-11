extends Node
## Голосовой чат: микрофон -> 16 кГц моно -> сжатие IMA ADPCM (4 бита на отсчёт) -> сервер ->
## остальные игроки. Сервер только пересылает байты. Звук уходит, пока ты говоришь (по громкости).
##
##   set_mic_enabled(true / false)   включить или выключить микрофон
##   voice_received(id игрока, отсчёты)   сигнал: пришёл голос, игрок его проигрывает

signal mic_state_changed(enabled: bool, message: String)
signal voice_received(owner_id: int, samples: PackedFloat32Array)

const VOICE_RATE := 16000
const FRAME_SAMPLES := 641        # 1 отсчёт в заголовке + 640 четырёхбитных кодов = 40 мс звука
const FRAME_SECONDS := 0.04
const MIC_BUS := "Mic"
const MIC_GAIN := 1.5             # усиление микрофона
const VAD_THRESHOLD := 0.012      # громкость (RMS), выше которой считаем, что ты говоришь
const VAD_HANGOVER := 0.4         # сколько секунд ещё передавать после последнего громкого кусочка
const NO_DATA_SECONDS := 3.0      # столько тишины с микрофона = «микрофон не работает»
const MAX_PACKET := 340           # пакеты больше этого размера отбрасываются
const PACKETS_PER_SECOND := 40    # лимит на сервере (обычно приходит 25)
const CONGESTION_BYTES := 262144  # сервер не шлёт голос тем, у кого очередь больше этого
const STEP_TABLE := [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]
const INDEX_TABLE := [-1, -1, -1, -1, 2, 4, 6, 8]

var mic_enabled := false
var local_speaking := false

var _capture: AudioEffectCapture
var _mic_player: AudioStreamPlayer
var _frame := PackedFloat32Array()
var _acc := 0.0
var _acc_count := 0
var _phase := 0.0
var _hang := 0.0
var _enc_index := 0
var _silent_time := 0.0
var _warned := false
var _counts := {}  # (на сервере) id игрока -> {"t": начало окна, "n": число пакетов}


func _ready() -> void:
	add_to_group("voice_net")


# ---------- микрофон ----------

func set_mic_enabled(on: bool) -> void:
	if not on:
		if mic_enabled or _mic_player != null:
			_stop_capture()
			mic_state_changed.emit(false, "")
		return
	if mic_enabled:
		return
	if OS.get_name() == "Android" and not _has_mic_permission():
		if not get_tree().on_request_permissions_result.is_connected(_on_permission_result):
			get_tree().on_request_permissions_result.connect(_on_permission_result)
		OS.request_permission("RECORD_AUDIO")
		return
	_start_capture()


func _has_mic_permission() -> bool:
	for permission in OS.get_granted_permissions():
		if str(permission).ends_with("RECORD_AUDIO"):
			return true
	return false


func _on_permission_result(permission: String, granted: bool) -> void:
	if not permission.ends_with("RECORD_AUDIO"):
		return
	if granted:
		_start_capture()
	else:
		mic_state_changed.emit(false, "Нет доступа к микрофону. Разреши его для игры в настройках Android.")


func _start_capture() -> void:
	var bus := AudioServer.get_bus_index(MIC_BUS)
	if bus == -1:
		AudioServer.add_bus()
		bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, MIC_BUS)
		AudioServer.set_bus_mute(bus, true)  # свой голос в динамик не выводим
		var effect := AudioEffectCapture.new()
		effect.buffer_length = 0.5
		AudioServer.add_bus_effect(bus, effect)
	_capture = AudioServer.get_bus_effect(bus, 0) as AudioEffectCapture
	if _capture == null:
		mic_state_changed.emit(false, "Не удалось подключить микрофон.")
		return
	_capture.clear_buffer()
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = MIC_BUS
	add_child(_mic_player)
	_mic_player.play()
	_frame.clear()
	_acc = 0.0
	_acc_count = 0
	_phase = 0.0
	_hang = 0.0
	_enc_index = 0
	_silent_time = 0.0
	_warned = false
	mic_enabled = true
	mic_state_changed.emit(true, "Микрофон включён: звук уходит, пока ты говоришь. В наушниках не будет эха.")


func _stop_capture() -> void:
	mic_enabled = false
	local_speaking = false
	if _mic_player != null:
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
	if _capture != null:
		_capture.clear_buffer()


func _process(delta: float) -> void:
	if mic_enabled and _capture != null:
		_pump(delta)


## Забирает звук с микрофона, переводит в 16 кГц моно (усреднением) и режет на кусочки по 40 мс.
func _pump(delta: float) -> void:
	var available := _capture.get_frames_available()
	if available <= 0:
		_silent_time += delta
		if _silent_time > NO_DATA_SECONDS and not _warned:
			_warned = true
			mic_state_changed.emit(true, "Микрофон молчит. Проверь разрешение и закрой другие приложения, которые его используют.")
		return
	_silent_time = 0.0
	var step := AudioServer.get_mix_rate() / float(VOICE_RATE)
	for stereo in _capture.get_buffer(available):
		_acc += (stereo.x + stereo.y) * 0.5
		_acc_count += 1
		_phase += 1.0
		if _phase >= step:
			_phase -= step
			_frame.append(clampf(_acc / float(_acc_count) * MIC_GAIN, -1.0, 1.0))
			_acc = 0.0
			_acc_count = 0
			if _frame.size() >= FRAME_SAMPLES:
				_finish_frame()


func _finish_frame() -> void:
	if _rms(_frame) > VAD_THRESHOLD:
		_hang = VAD_HANGOVER
	else:
		_hang = maxf(_hang - FRAME_SECONDS, 0.0)
	local_speaking = _hang > 0.0
	if local_speaking:
		_send_voice(_encode(_frame))
	_frame.clear()


func _rms(samples: PackedFloat32Array) -> float:
	var sum := 0.0
	for value in samples:
		sum += value * value
	return sqrt(sum / maxf(float(samples.size()), 1.0))


# ---------- передача ----------

func _send_voice(data: PackedByteArray) -> void:
	if multiplayer.is_server():
		_relay(multiplayer.get_unique_id(), data)
	else:
		rpc_id(1, "server_voice", data)


@rpc("any_peer", "call_remote", "reliable")
func server_voice(data: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if data.size() < 4 or data.size() > MAX_PACKET or not _allowed(sender):
		return
	_relay(sender, data)


@rpc("authority", "call_remote", "reliable")
func client_voice(owner_id: int, data: PackedByteArray) -> void:
	_receive(owner_id, data)


## Сервер рассылает голос всем, кроме говорящего. Тем, у кого забита очередь, не шлёт:
## иначе их связь с сервером и задержка звука только ухудшатся.
func _relay(sender: int, data: PackedByteArray) -> void:
	for peer in multiplayer.get_peers():
		if peer != sender and not _congested(peer):
			rpc_id(peer, "client_voice", sender, data)
	# Сервер с экраном (тест на телефоне) тоже слышит игроков.
	if sender != multiplayer.get_unique_id() and DisplayServer.get_name() != "headless":
		_receive(sender, data)


func _receive(owner_id: int, data: PackedByteArray) -> void:
	var samples := _decode(data)
	if not samples.is_empty():
		voice_received.emit(owner_id, samples)


func _congested(peer: int) -> bool:
	var transport := multiplayer.multiplayer_peer as WebSocketMultiplayerPeer
	if transport == null:
		return false
	var socket: WebSocketPeer = transport.get_peer(peer)
	return socket != null and socket.get_current_outbound_buffered_amount() > CONGESTION_BYTES


## Не больше PACKETS_PER_SECOND пакетов в секунду от одного игрока.
func _allowed(peer: int) -> bool:
	var now := Time.get_ticks_msec()
	var entry: Dictionary = _counts.get(peer, {"t": now, "n": 0})
	if now - int(entry["t"]) >= 1000:
		entry = {"t": now, "n": 0}
	entry["n"] = int(entry["n"]) + 1
	_counts[peer] = entry
	return int(entry["n"]) <= PACKETS_PER_SECOND


# ---------- сжатие IMA ADPCM ----------

## Заголовок 3 байта (первый отсчёт и индекс шага), дальше по 4 бита на каждый следующий отсчёт.
## Заголовок есть в каждом пакете, поэтому потеря пакета не портит следующие.
func _encode(samples: PackedFloat32Array) -> PackedByteArray:
	var count := samples.size()
	var first := clampi(int(samples[0] * 32767.0), -32768, 32767)
	var predictor := first
	var index := _enc_index
	var out := PackedByteArray()
	out.resize(3 + count / 2)
	out.encode_s16(0, first)
	out.encode_u8(2, index)
	var pos := 3
	var have_low := false
	var low := 0
	for i in range(1, count):
		var target := clampi(int(samples[i] * 32767.0), -32768, 32767)
		var diff := target - predictor
		var code := 0
		if diff < 0:
			code = 8
			diff = -diff
		var step: int = STEP_TABLE[index]
		var vpdiff := step >> 3
		if diff >= step:
			code |= 4
			diff -= step
			vpdiff += step
		step >>= 1
		if diff >= step:
			code |= 2
			diff -= step
			vpdiff += step
		step >>= 1
		if diff >= step:
			code |= 1
			vpdiff += step
		if code & 8:
			predictor -= vpdiff
		else:
			predictor += vpdiff
		predictor = clampi(predictor, -32768, 32767)
		index = clampi(index + int(INDEX_TABLE[code & 7]), 0, 88)
		if have_low:
			out[pos] = low | (code << 4)
			pos += 1
			have_low = false
		else:
			low = code
			have_low = true
	if have_low:
		out[pos] = low
		pos += 1
	_enc_index = index
	out.resize(pos)
	return out


func _decode(data: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if data.size() < 4 or data.size() > MAX_PACKET:
		return out
	var predictor := data.decode_s16(0)
	var index := clampi(data.decode_u8(2), 0, 88)
	out.append(predictor / 32768.0)
	for pos in range(3, data.size()):
		var byte := data[pos]
		for half in 2:
			var code := (byte >> (4 * half)) & 15
			var step: int = STEP_TABLE[index]
			var vpdiff := step >> 3
			if code & 4:
				vpdiff += step
			if code & 2:
				vpdiff += step >> 1
			if code & 1:
				vpdiff += step >> 2
			if code & 8:
				predictor -= vpdiff
			else:
				predictor += vpdiff
			predictor = clampi(predictor, -32768, 32767)
			index = clampi(index + int(INDEX_TABLE[code & 7]), 0, 88)
			out.append(predictor / 32768.0)
	return out
