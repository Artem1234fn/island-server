extends CharacterBody3D
## Игрок. Имя узла = id владельца. Двигает персонажа только владелец,
## остальным позиция и поворот приходят через MultiplayerSynchronizer.
## Скин (части модели) приходит отдельно через SkinNet.
## Камера у владельца жёстко следует за игроком (без сглаживания, иначе картинка «плывёт»): палец на правой половине экрана её вращает,
## а джойстик на левой двигает персонажа относительно камеры. Если камера упирается в пол,
## она приближается к игроку.

const SPEED := 6.0
const GRAVITY := 25.0
const TURN_SPEED := 12.0
const CAM_DISTANCE := 5.5         # расстояние от камеры до игрока
const CAM_DISTANCE_MIN := 1.2     # ближе камера не подходит, даже у самого пола
const CAM_MARGIN := 0.4           # зазор между камерой и полом
const CAM_HEIGHT := 0.7           # камера смотрит чуть выше центра капсулы (на голову)
const CAM_PITCH_MIN := -0.9       # камера может опуститься к полу (тогда она приближается)
const CAM_PITCH_MAX := 1.2        # максимальный наклон (почти сверху)
const LOOK_SENSITIVITY := 0.0055  # радиан на один пиксель сдвига пальца
const FALL_LIMIT := -40.0         # ниже этой высоты игрок возвращается на остров
const BUBBLE_HEIGHT := 2.35       # высота пузыря над центром капсулы (над ником)
const BUBBLE_SECONDS := 6.0       # сколько секунд пузырь висит над головой
const BUBBLE_FADE := 1.0          # последнюю секунду пузырь плавно гаснет
const BUBBLE_MAX_CHARS := 140     # длинные сообщения в пузыре обрезаются
const BUBBLE_PAD := Vector2(0.35, 0.2)  # поля вокруг текста
const VOICE_RATE := 16000.0       # частота голоса (как в voice_net.gd)
const VOICE_UNIT_SIZE := 12.0     # до этого расстояния голос слышен в полную силу, дальше тише
const VOICE_PREROLL := 3          # сколько кусочков (по 40 мс) копим перед началом речи
const VOICE_MAX_QUEUE := 12       # если накопилось больше, старое выбрасываем

var _controls: Node
var _skin: Node3D
var _pivots := {}
var _last_pos := Vector3.ZERO
var _speed := 0.0
var _phase := 0.0
var _cam_yaw := 0.0
var _cam_pitch := 0.35
var _cam_distance := CAM_DISTANCE
var _cam_focus := Vector3.ZERO
var _bubble: Label3D
var _bubble_bg: MeshInstance3D
var _bubble_time := 0.0
var _voice_net: Node
var _voice_player: AudioStreamPlayer3D
var _voice_playback: AudioStreamGeneratorPlayback
var _voice_queue: Array[PackedFloat32Array] = []
var _voice_active := false
var _voice_idle := 0.0
var _speaking := 0.0

@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _nose: MeshInstance3D = $Body/Nose
@onready var _camera: Camera3D = $Camera3D
@onready var _name_label: Label3D = $NameLabel


func _enter_tree() -> void:
	# Владелец игрока - тот, чей id записан в имени узла.
	set_multiplayer_authority(str(name).to_int())


func _ready() -> void:
	_update_label()
	_paint(str(name).to_int())
	_last_pos = global_position
	if is_multiplayer_authority():
		_camera.top_level = true  # камера живёт сама по себе и облетает игрока
		_camera.make_current()
		_controls = get_tree().get_first_node_in_group("touch_controls")
		_cam_focus = global_position + Vector3(0.0, CAM_HEIGHT, 0.0)
		_update_camera(0.0)
	else:
		_camera.queue_free()
	# Серверу (без экрана) скины не нужны.
	if DisplayServer.get_name() != "headless":
		var net = get_tree().get_first_node_in_group("skin_net")
		if net != null:
			net.skin_ready.connect(_on_skin_ready)
		_make_bubble()
		_voice_net = get_tree().get_first_node_in_group("voice_net")
		if _voice_net != null:
			_voice_net.voice_received.connect(_on_voice_received)
		if not is_multiplayer_authority():
			_make_voice_player()
		var chat = get_tree().get_first_node_in_group("chat_net")
		if chat != null:
			chat.nick_changed.connect(_on_nick_changed)
			chat.message_received.connect(_on_chat_message)
		_load_skin()


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if _controls:
		input += _controls.get("move_vector")
	input = input.limit_length(1.0)

	# Движение относительно камеры: палец вверх = туда, куда смотрит камера.
	var forward := Vector3(-sin(_cam_yaw), 0.0, -cos(_cam_yaw))
	var right := Vector3(cos(_cam_yaw), 0.0, -sin(_cam_yaw))
	var direction := right * input.x + forward * -input.y
	velocity.x = direction.x * SPEED
	velocity.z = direction.z * SPEED
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()

	if direction.length() > 0.1:
		var target_angle := atan2(-direction.x, -direction.z)
		_body.rotation.y = lerp_angle(_body.rotation.y, target_angle, TURN_SPEED * delta)

	if global_position.y < FALL_LIMIT:
		_respawn()
	_update_camera_distance(delta)


## Камера обновляется каждый кадр, а анимация ходьбы (как у R6: ноги и руки качаются в
## противофазе) работает у всех игроков: скорость берётся из того, как меняется позиция.
func _process(delta: float) -> void:
	_update_voice(delta)
	if _bubble_time > 0.0:
		_bubble_time -= delta
		if _bubble_time <= 0.0:
			_bubble.visible = false
			_bubble_bg.visible = false
		else:
			var alpha := clampf(_bubble_time / BUBBLE_FADE, 0.0, 1.0)
			_bubble.modulate.a = alpha
			_bubble_bg.transparency = 1.0 - alpha
	if is_multiplayer_authority():
		_update_camera(delta)
	if _pivots.is_empty():
		return
	var step := Vector2(global_position.x - _last_pos.x, global_position.z - _last_pos.z)
	_last_pos = global_position
	var raw_speed := step.length() / maxf(delta, 0.0001)
	_speed = lerpf(_speed, raw_speed, 1.0 - exp(-10.0 * delta))
	var walk := clampf(_speed / SPEED, 0.0, 1.0)
	_phase += delta * walk * 9.0
	var swing := sin(_phase) * walk * 0.8
	_set_swing("leg_r", swing)
	_set_swing("leg_l", -swing)
	_set_swing("arm_l", swing)
	_set_swing("arm_r", -swing)


## Единичный вектор от игрока к камере. Угол yaw = 0 значит камера позади игрока (на +Z).
func _camera_direction() -> Vector3:
	return Vector3(sin(_cam_yaw) * cos(_cam_pitch), sin(_cam_pitch), cos(_cam_yaw) * cos(_cam_pitch))


## Камера стоит позади игрока на расстоянии _cam_distance и двигается вместе с ним.
## Палец вправо поворачивает вид вправо, палец вверх поднимает взгляд.
func _update_camera(_delta: float) -> void:
	if _controls != null:
		var look: Vector2 = _controls.call("consume_look")
		_cam_yaw -= look.x * LOOK_SENSITIVITY
		_cam_pitch = clampf(_cam_pitch + look.y * LOOK_SENSITIVITY, CAM_PITCH_MIN, CAM_PITCH_MAX)
	var goal := global_position + Vector3(0.0, CAM_HEIGHT, 0.0)
	# Без сглаживания: игрок двигается шагами физики, и плавная камера рассинхронизировалась бы
	# с ним по кадрам, из-за чего игрок и подпись над ним выглядели размытыми.
	_cam_focus = goal
	var cam_pos := _cam_focus + _camera_direction() * _cam_distance
	if goal.y > -0.5:  # пока игрок над островом, камера не уходит под пол; при падении следует вниз
		cam_pos.y = maxf(cam_pos.y, 0.2)
	_camera.look_at_from_position(cam_pos, _cam_focus, Vector3.UP)


## Если на пути от игрока к камере есть пол, камера приближается: сразу, чтобы не было
## «проваливания» под землю, а обратно отъезжает плавно. Отступ считается так, чтобы камера
## оказалась на CAM_MARGIN от самой поверхности, а не просто от точки на луче.
func _update_camera_distance(delta: float) -> void:
	var from := _cam_focus
	var dir := _camera_direction()
	var to := from + dir * (CAM_DISTANCE + CAM_MARGIN / 0.15)
	var exclude: Array[RID] = [get_rid()]
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var wanted := CAM_DISTANCE
	if not hit.is_empty():
		var normal: Vector3 = hit["normal"]
		var back := CAM_MARGIN / maxf(-dir.dot(normal), 0.15)
		wanted = clampf(from.distance_to(hit["position"]) - back, CAM_DISTANCE_MIN, CAM_DISTANCE)
	if wanted < _cam_distance:
		_cam_distance = wanted
	else:
		_cam_distance = lerpf(_cam_distance, wanted, 1.0 - exp(-6.0 * delta))


## Упал с острова слишком глубоко: возвращаемся на остров.
func _respawn() -> void:
	global_position = Vector3(randf_range(-6.0, 6.0), 1.0, randf_range(-6.0, 6.0))
	velocity = Vector3.ZERO
	_cam_focus = global_position + Vector3(0.0, CAM_HEIGHT, 0.0)
	_cam_distance = CAM_DISTANCE
	_last_pos = global_position


func _set_swing(part: String, angle: float) -> void:
	if _pivots.has(part):
		(_pivots[part] as Node3D).rotation.x = angle


func _paint(id: int) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_hsv(float(id % 360) / 360.0, 0.65, 0.95)
	_mesh.material_override = material


## Над игроком показывается его ник, а если ник не задан, то «Игрок <id>».
func _update_label() -> void:
	var nick := ""
	var chat = get_tree().get_first_node_in_group("chat_net")
	if chat != null:
		nick = chat.get_nick(str(name).to_int())
	_name_label.text = nick if nick != "" else "Игрок " + str(name)


## Пузырь с текстом над головой: тёмный текст на светлой плашке, всегда повёрнут к камере.
func _make_bubble() -> void:
	_bubble = Label3D.new()
	_bubble.name = "ChatBubble"
	_bubble.position = Vector3(0.0, BUBBLE_HEIGHT, 0.0)
	_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble.pixel_size = 0.0125
	_bubble.font_size = 36
	_bubble.outline_size = 0
	_bubble.width = 300.0
	_bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bubble.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_bubble.modulate = Color(0.08, 0.08, 0.1, 1.0)
	_bubble.no_depth_test = true
	_bubble.render_priority = 1
	_bubble.visible = false
	add_child(_bubble)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.92)
	_bubble_bg = MeshInstance3D.new()
	_bubble_bg.name = "ChatBubbleBackground"
	_bubble_bg.position = Vector3(0.0, BUBBLE_HEIGHT, 0.0)
	_bubble_bg.mesh = QuadMesh.new()
	_bubble_bg.material_override = material
	_bubble_bg.visible = false
	add_child(_bubble_bg)


func _on_chat_message(sender_id: int, _nick: String, text: String) -> void:
	if sender_id == str(name).to_int() and _bubble != null:
		_show_bubble(text)


func _show_bubble(text: String) -> void:
	var shown := text
	if shown.length() > BUBBLE_MAX_CHARS:
		shown = shown.substr(0, BUBBLE_MAX_CHARS) + "…"
	_bubble.text = shown
	_bubble.modulate.a = 1.0
	_bubble.visible = true
	_bubble_bg.visible = false
	_bubble_bg.transparency = 0.0
	_bubble_time = BUBBLE_SECONDS
	# Label3D пересчитывает размер текста на следующем кадре, плашку подгоняем под него.
	await get_tree().process_frame
	if _bubble_time <= 0.0:
		return
	var box := _bubble.get_aabb()
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return
	var quad := _bubble_bg.mesh as QuadMesh
	quad.size = Vector2(box.size.x + BUBBLE_PAD.x, box.size.y + BUBBLE_PAD.y)
	quad.center_offset = Vector3(box.position.x + box.size.x * 0.5, box.position.y + box.size.y * 0.5, -0.02)
	_bubble_bg.visible = true


## Голос другого игрока звучит из его позиции: чем дальше, тем тише.
func _make_voice_player() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = VOICE_RATE
	generator.set("mix_rate_mode", 2)  # своя частота, а не частота вывода
	generator.buffer_length = 0.4
	_voice_player = AudioStreamPlayer3D.new()
	_voice_player.name = "Voice"
	_voice_player.position = Vector3(0.0, 1.5, 0.0)
	_voice_player.unit_size = VOICE_UNIT_SIZE
	_voice_player.stream = generator
	add_child(_voice_player)
	_voice_player.play()
	_voice_playback = _voice_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _on_voice_received(owner_id: int, samples: PackedFloat32Array) -> void:
	if owner_id != str(name).to_int() or _voice_playback == null:
		return
	_voice_queue.append(samples)
	_speaking = 0.5
	while _voice_queue.size() > VOICE_MAX_QUEUE:
		_voice_queue.pop_front()


## Ник подсвечивается зелёным, пока игрок говорит; чужой голос подаётся в проигрыватель.
func _update_voice(delta: float) -> void:
	var speaking_now := false
	if is_multiplayer_authority():
		if _voice_net != null:
			speaking_now = _voice_net.local_speaking
	else:
		_speaking = maxf(_speaking - delta, 0.0)
		speaking_now = _speaking > 0.0
		_feed_voice(delta)
	_name_label.modulate = Color(0.45, 1.0, 0.45) if speaking_now else Color.WHITE


func _feed_voice(delta: float) -> void:
	if _voice_playback == null:
		return
	# Речь начинаем, когда накоплено немного звука: запас на неровную доставку.
	if not _voice_active:
		if _voice_queue.size() < VOICE_PREROLL:
			return
		_voice_active = true
	while not _voice_queue.is_empty():
		var chunk: PackedFloat32Array = _voice_queue[0]
		if _voice_playback.get_frames_available() < chunk.size():
			break
		_voice_queue.pop_front()
		var frames := PackedVector2Array()
		frames.resize(chunk.size())
		for i in chunk.size():
			frames[i] = Vector2(chunk[i], chunk[i])
		_voice_playback.push_buffer(frames)
	if _voice_queue.is_empty():
		_voice_idle += delta
		if _voice_idle > 0.4:
			_voice_active = false  # речь закончилась: в следующий раз снова накопим запас
			_voice_idle = 0.0
	else:
		_voice_idle = 0.0


func _on_nick_changed(peer_id: int) -> void:
	if peer_id == str(name).to_int():
		_update_label()


func _on_skin_ready(owner_id: int) -> void:
	if owner_id == str(name).to_int():
		_load_skin()


func _load_skin() -> void:
	var net = get_tree().get_first_node_in_group("skin_net")
	var importer = get_tree().get_first_node_in_group("skin_importer")
	if net == null or importer == null:
		return
	var pack: Dictionary = net.get_skin(str(name).to_int())
	if pack.is_empty():
		return
	var parts: Dictionary = importer.build_parts(pack)
	_apply_skin(parts, float(pack.get("yaw", 0.0)))


func _apply_skin(parts: Dictionary, yaw: float) -> void:
	_clear_skin()
	_skin = Node3D.new()
	_skin.name = "Skin"
	_skin.position = Vector3(0.0, -1.0, 0.0)  # ноги на уровне низа капсулы
	_skin.rotation.y = yaw
	_body.add_child(_skin)
	for part_name in parts:
		var info: Dictionary = parts[part_name]
		var pivot_pos: Vector3 = info["pivot"]
		var pivot := Node3D.new()
		pivot.name = part_name
		pivot.position = pivot_pos
		_skin.add_child(pivot)
		var piece := MeshInstance3D.new()
		piece.mesh = info["mesh"]
		piece.position = -pivot_pos
		pivot.add_child(piece)
		_pivots[part_name] = pivot
	_mesh.visible = false
	_nose.visible = false
	_last_pos = global_position
	_speed = 0.0


func _clear_skin() -> void:
	if _skin != null:
		_skin.queue_free()
		_skin = null
	_pivots.clear()
	_mesh.visible = true
	_nose.visible = true
