extends Node3D
## Главная сцена.
## Клиент: кнопка «Играть» подключает к общему серверу.
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
const PLAYER_SCENE := preload("res://player.tscn")

@onready var _players: Node3D = $Players
@onready var _menu: Control = $UI/Menu
@onready var _status: Label = $UI/StatusLabel
@onready var _touch_controls: Control = $UI/TouchControls

var _connecting := false
var _attempt := 0
var _deadline_msec := 0


func _ready() -> void:
	$UI/Menu/PlayButton.pressed.connect(_on_play_pressed)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_touch_controls.hide()

	# Режим выделенного сервера: игрока у сервера нет, меню не нужно.
	if "--server" in OS.get_cmdline_user_args():
		_start_server(false)


func _on_play_pressed() -> void:
	if SERVER_URL.is_empty():
		# Общий сервер ещё не задан: тест на этом телефоне, игрок один.
		if _start_server(true):
			_set_status("Тест на этом телефоне. Впиши адрес сервера в SERVER_URL (main.gd)")
		return
	_menu.hide()
	_connecting = true
	_deadline_msec = Time.get_ticks_msec() + int(CONNECT_TOTAL_TIMEOUT * 1000.0)
	_try_connect()


func _try_connect() -> void:
	_attempt += 1
	var token := _attempt
	var peer := WebSocketMultiplayerPeer.new()
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
		_give_up("Не удалось подключиться к серверу. Проверь интернет и попробуй ещё раз.")
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
	var err := peer.create_server(port)
	if err != OK:
		_set_status("Не удалось создать сервер: %s" % error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	_menu.hide()
	if with_player:
		_spawn_player(1)
		_touch_controls.show()
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
	_touch_controls.show()
	_set_status("Ты на острове! Твой id: %d" % multiplayer.get_unique_id())


func _on_server_disconnected() -> void:
	_connecting = false
	_attempt += 1
	multiplayer.multiplayer_peer = null
	for child in _players.get_children():
		child.queue_free()
	_touch_controls.hide()
	_menu.show()
	_set_status("Связь с сервером потеряна.")


func _set_status(message: String) -> void:
	_status.text = message
	print(message)
