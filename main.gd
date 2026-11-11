extends Node3D
## Главная сцена.
## В меню: ник, «Скин: выбрать файл» (до подключения) и «Играть».
## На острове справа вверху: «Чат» и «Выйти».
## Сервер (без экрана):
##   godot --headless --path <папка проекта> -- --server
## Порт сервер берёт из переменной окружения PORT (так делает Render), иначе 7777.

## Адрес общего сервера:
##   Render: "wss://имя-сервиса.onrender.com"
##   VPS:    "ws://203.0.113.10:7777"
## Пока пусто, кнопка «Играть» запускает тест прямо на этом телефоне.
const SERVER_URL := ""
const DEFAULT_PORT := 7777
const CONNECT_TOTAL_TIMEOUT := 100.0 # бесплатный сервер может просыпаться до минуты
const ATTEMPT_TIMEOUT := 20.0
const RETRY_DELAY := 3.0
const MAX_SKIN_BYTES := 8 * 1024 * 1024
const MAX_NICK := 16
const CHAT_LINES := 8              # сколько последних сообщений показывать
const CHAT_FADE_SECONDS := 12.0    # через сколько секунд тишины лента чата прячется
const SETTINGS_PATH := "user://island.cfg"
const PLAYER_SCENE := preload("res://player.tscn")

@onready var _players: Node3D = $Players
@onready var _menu: Control = $UI/Menu
@onready var _nick_edit: LineEdit = $UI/Menu/NickEdit
@onready var _play_button: Button = $UI/Menu/PlayButton
@onready var _skin_button: Button = $UI/Menu/SkinButton
@onready var _status: Label = $UI/StatusLabel
@onready var _touch_controls: Control = $UI/TouchControls
@onready var _game_panel: Control = $UI/GamePanel
@onready var _chat_button: Button = $UI/GamePanel/ChatButton
@onready var _exit_button: Button = $UI/GamePanel/ExitButton
@onready var _mic_button: Button = $UI/GamePanel/MicButton
@onready var _chat_panel: Control = $UI/ChatPanel
@onready var _chat_log_panel: Control = $UI/ChatPanel/LogPanel
@onready var _chat_log: Label = $UI/ChatPanel/LogPanel/ChatLog
@onready var _chat_row: Control = $UI/ChatPanel/ChatRow
@onready var _chat_input: LineEdit = $UI/ChatPanel/ChatRow/ChatInput
@onready var _send_button: Button = $UI/ChatPanel/ChatRow/SendButton
@onready var _skin_net = $SkinNet
@onready var _chat_net = $ChatNet
@onready var _voice_net = $VoiceNet
@onready var _importer = $SkinImporter

var _dialog: FileDialog
var _my_pack := {}  # готовый скин: выбирается в меню, уходит остальным после подключения
var _my_data := PackedByteArray()
var _my_nick := ""
var _chat_lines: Array[String] = []
var _chat_idle := 0.0
var _connecting := false
var _attempt := 0
var _deadline_msec := 0


func _ready() -> void:
	_play_button.pressed.connect(_on_play_pressed)
	_skin_button.pressed.connect(_on_skin_button_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_chat_button.pressed.connect(_on_chat_button_pressed)
	_send_button.pressed.connect(_on_chat_send_pressed)
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_net.message_received.connect(_on_chat_message)
	_mic_button.pressed.connect(_on_mic_pressed)
	_voice_net.mic_state_changed.connect(_on_mic_state)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_show_game_ui(false)

	# Режим выделенного сервера: игрока у сервера нет, меню и окно выбора файла не нужны.
	if "--server" in OS.get_cmdline_user_args():
		_start_server(false)
		return

	_nick_edit.text = _load_nick()

	_dialog = FileDialog.new()
	_dialog.title = "Выбери файл скина"
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.use_native_dialog = true
	_dialog.filters = PackedStringArray(["*.glb, *.zip ; Скин (.glb или .zip)"])
	_dialog.file_selected.connect(_on_skin_file_selected)
	add_child(_dialog)


func _process(delta: float) -> void:
	# Лента чата прячется после тишины, если ввод закрыт.
	if _chat_idle > 0.0:
		_chat_idle -= delta
		if _chat_idle <= 0.0 and not _chat_row.visible:
			_chat_log_panel.hide()


func _show_game_ui(shown: bool) -> void:
	_touch_controls.visible = shown
	_game_panel.visible = shown
	_chat_panel.visible = shown
	if not shown:
		_close_chat_input()
		_voice_net.set_mic_enabled(false)
		_chat_lines.clear()
		_chat_log.text = ""
		_chat_log_panel.hide()


# ---------- ник ----------

func _load_nick() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		return str(cfg.get_value("player", "nick", ""))
	return ""


func _save_nick(nick: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # чтобы не потерять другие значения, если они появятся
	cfg.set_value("player", "nick", nick)
	cfg.save(SETTINGS_PATH)


# ---------- чат ----------

func _on_chat_button_pressed() -> void:
	if _chat_row.visible:
		_close_chat_input()
		return
	_chat_row.show()
	_chat_log_panel.visible = not _chat_lines.is_empty()
	_touch_controls.set("enabled", false)  # пока печатаем, джойстик и камера не реагируют
	_chat_input.grab_focus()


func _on_chat_send_pressed() -> void:
	_submit_chat(_chat_input.text)


func _on_chat_submitted(text: String) -> void:
	_submit_chat(text)


func _submit_chat(raw: String) -> void:
	var text := raw.strip_edges()
	if not text.is_empty():
		_chat_net.send(text)
	_chat_input.clear()
	_close_chat_input()


func _close_chat_input() -> void:
	_chat_input.release_focus()
	_chat_row.hide()
	_touch_controls.set("enabled", true)
	DisplayServer.virtual_keyboard_hide()


func _on_chat_message(sender_id: int, nick: String, text: String) -> void:
	var who := nick if nick != "" else "Игрок %d" % sender_id
	_chat_lines.append("%s: %s" % [who, text])
	while _chat_lines.size() > CHAT_LINES:
		_chat_lines.pop_front()
	_chat_log.text = "\n".join(_chat_lines)
	_chat_log_panel.show()
	_chat_idle = CHAT_FADE_SECONDS


# ---------- голос ----------

func _on_mic_pressed() -> void:
	_voice_net.set_mic_enabled(not _voice_net.mic_enabled)


func _on_mic_state(enabled: bool, message: String) -> void:
	_mic_button.text = "Микр: вкл" if enabled else "Микр: выкл"
	if message != "":
		_set_status(message)


# ---------- скин (до подключения) ----------

func _on_skin_button_pressed() -> void:
	if _dialog != null:
		_dialog.popup_centered_ratio(0.9)


## Файл скина выбран: разбираем его и запоминаем. Игрокам он уйдёт после нажатия «Играть».
## Всё делается в меню, пока нет соединения: системное окно выбора файла сворачивает игру,
## и на острове из-за этого рвалась бы связь с сервером.
func _on_skin_file_selected(path: String) -> void:
	_play_button.disabled = true
	_skin_button.disabled = true
	_set_status("Читаю файл скина…")
	var pack: Dictionary = await _importer.import_file(path)
	if pack.is_empty():
		_set_status("Скин не загружен: " + _importer.last_error)
	else:
		var data: PackedByteArray = _importer.pack_to_bytes(pack)
		var megabytes := data.size() / 1048576.0
		if data.size() > MAX_SKIN_BYTES:
			_set_status("Скин слишком тяжёлый: %.1f МБ после сжатия, максимум 8 МБ. Возьми модель попроще." % megabytes)
		else:
			_my_pack = pack
			_my_data = data
			_skin_button.text = "Скин выбран (сменить)"
			_set_status("Скин готов (%.1f МБ). Нажми «Играть»." % megabytes)
	_play_button.disabled = false
	_skin_button.disabled = false


## Отправляет выбранный скин остальным игрокам (после подключения к острову).
func _send_my_skin() -> void:
	if _my_pack.is_empty():
		return
	await _skin_net.submit(multiplayer.get_unique_id(), _my_pack, _my_data)


# ---------- подключение ----------

func _on_play_pressed() -> void:
	_my_nick = _nick_edit.text.strip_edges().substr(0, MAX_NICK)
	_save_nick(_my_nick)
	if SERVER_URL.is_empty():
		# Общий сервер ещё не задан: тест на этом телефоне, игрок один.
		if _start_server(true):
			_set_status("Тест на этом телефоне. Впиши адрес сервера в SERVER_URL (main.gd)")
		return
	_menu.hide()
	_connecting = true
	_deadline_msec = Time.get_ticks_msec() + int(CONNECT_TOTAL_TIMEOUT * 1000.0)
	_try_connect()


## Скины передаются кусками, поэтому буферы увеличены (если в этой версии Godot есть такие свойства).
func _tune(peer: WebSocketMultiplayerPeer) -> void:
	peer.set("inbound_buffer_size", 4194304)
	peer.set("outbound_buffer_size", 4194304)
	peer.set("max_queued_packets", 8192)


func _try_connect() -> void:
	_attempt += 1
	var token := _attempt
	var peer := WebSocketMultiplayerPeer.new()
	_tune(peer)
	var err := peer.create_client(SERVER_URL)
	if err != OK:
		_give_up("Не удалось начать подключение: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	_set_status("Подключение… Бесплатный сервер может просыпаться до минуты.")
	# Если ответа нет слишком долго, считаем попытку неудачной.
	await get_tree().create_timer(ATTEMPT_TIMEOUT).timeout
	if _connecting and token == _attempt:
		_on_connection_failed()


func _on_connection_failed() -> void:
	_attempt += 1
	var token := _attempt
	multiplayer.multiplayer_peer = null
	if not _connecting:
		return
	if Time.get_ticks_msec() >= _deadline_msec:
		_give_up("Не удалось подключиться к серверу. Проверь интернет (возможно, нужен VPN) и попробуй ещё раз.")
		return
	_set_status("Сервер просыпается, пробую ещё раз…")
	await get_tree().create_timer(RETRY_DELAY).timeout
	if _connecting and token == _attempt:
		_try_connect()


func _give_up(message: String) -> void:
	_connecting = false
	_attempt += 1
	multiplayer.multiplayer_peer = null
	_menu.show()
	_set_status(message)


func _start_server(with_player: bool) -> bool:
	var port := DEFAULT_PORT
	if OS.has_environment("PORT"):
		port = int(OS.get_environment("PORT"))
	var peer := WebSocketMultiplayerPeer.new()
	_tune(peer)
	var err := peer.create_server(port)
	if err != OK:
		_set_status("Не удалось создать сервер: %s" % error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	_menu.hide()
	if with_player:
		_spawn_player(1)
		_show_game_ui(true)
		_chat_net.set_my_nick(_my_nick)
		_send_my_skin()
	else:
		print("Выделенный сервер запущен, порт ", port)
	return true


func _spawn_player(id: int) -> void:
	var player := PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = str(id)
	player.position = Vector3(randf_range(-6.0, 6.0), 1.0, randf_range(-6.0, 6.0))
	_players.add_child(player, true)


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_spawn_player(id)
		print("Игрок подключился: ", id)


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		var player := _players.get_node_or_null(str(id))
		if player:
			player.queue_free()
		print("Игрок вышел: ", id)


func _on_connected_to_server() -> void:
	_connecting = false
	_attempt += 1
	_show_game_ui(true)
	_set_status("Ты на острове! Твой id: %d" % multiplayer.get_unique_id())
	# Сообщаем свой ник, просим у сервера ники и скины тех, кто уже на острове, и отдаём свой скин.
	_chat_net.set_my_nick(_my_nick)
	_chat_net.request_all()
	_skin_net.request_all()
	_send_my_skin()


func _on_server_disconnected() -> void:
	_connecting = false
	_attempt += 1
	multiplayer.multiplayer_peer = null
	for child in _players.get_children():
		child.queue_free()
	_show_game_ui(false)
	_menu.show()
	_set_status("Связь с сервером потеряна.")


## Кнопка «Выйти»: возвращаемся в меню, там можно сменить скин и зайти снова.
func _on_exit_pressed() -> void:
	_connecting = false
	_attempt += 1
	multiplayer.multiplayer_peer = null
	for child in _players.get_children():
		child.queue_free()
	_show_game_ui(false)
	_menu.show()
	_set_status("Ты вышел с острова. Можно сменить скин или снова нажать «Играть».")


func _set_status(message: String) -> void:
	_status.text = message
	print(message)
