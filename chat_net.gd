extends Node
## Текстовый чат и ники игроков. Сервер проверяет и рассылает сообщения, клиенты только показывают.
## Ник и сообщение сервер всегда очищает сам: клиенту доверять нельзя.

signal message_received(sender_id: int, nick: String, text: String)
signal nick_changed(peer_id: int)

const MAX_TEXT := 200
const MAX_NICK := 16
const RATE_WINDOW_MSEC := 5000  # за это время...
const RATE_LIMIT := 6           # ...можно отправить не больше стольких сообщений

var _nicks := {}   # id игрока -> ник
var _recent := {}  # (на сервере) id игрока -> времена последних сообщений


func _ready() -> void:
	add_to_group("chat_net")
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func get_nick(peer_id: int) -> String:
	return _nicks.get(peer_id, "")


## Сообщает серверу свой ник (пустой ник = «Игрок <id>»).
func set_my_nick(nick: String) -> void:
	if multiplayer.is_server():
		_apply_nick(multiplayer.get_unique_id(), nick)
	else:
		rpc_id(1, "server_set_nick", nick)


## Отправляет сообщение в общий чат.
func send(text: String) -> void:
	if multiplayer.is_server():
		_handle_message(multiplayer.get_unique_id(), text)
	else:
		rpc_id(1, "server_send", text)


## Новый игрок просит у сервера ники тех, кто уже на острове.
func request_all() -> void:
	if not multiplayer.is_server():
		rpc_id(1, "server_hello")


@rpc("any_peer", "call_remote", "reliable")
func server_set_nick(nick: String) -> void:
	if multiplayer.is_server():
		_apply_nick(multiplayer.get_remote_sender_id(), nick)


@rpc("any_peer", "call_remote", "reliable")
func server_send(text: String) -> void:
	if multiplayer.is_server():
		_handle_message(multiplayer.get_remote_sender_id(), text)


@rpc("any_peer", "call_remote", "reliable")
func server_hello() -> void:
	if not multiplayer.is_server():
		return
	var requester := multiplayer.get_remote_sender_id()
	for peer_id in _nicks:
		rpc_id(requester, "client_nick", peer_id, _nicks[peer_id])


@rpc("authority", "call_remote", "reliable")
func client_nick(peer_id: int, nick: String) -> void:
	_nicks[peer_id] = _clean_nick(nick)
	nick_changed.emit(peer_id)


@rpc("authority", "call_remote", "reliable")
func client_message(sender_id: int, nick: String, text: String) -> void:
	message_received.emit(sender_id, _clean_nick(nick), _clean_text(text))


func _apply_nick(peer_id: int, nick: String) -> void:
	var clean := _clean_nick(nick)
	_nicks[peer_id] = clean
	for peer in multiplayer.get_peers():
		rpc_id(peer, "client_nick", peer_id, clean)
	# Сервер с экраном (тест на телефоне) тоже показывает ники.
	if DisplayServer.get_name() != "headless":
		nick_changed.emit(peer_id)


func _handle_message(sender: int, text: String) -> void:
	var clean := _clean_text(text)
	if clean.is_empty() or not _allowed(sender):
		return
	var nick: String = _nicks.get(sender, "")
	for peer in multiplayer.get_peers():
		rpc_id(peer, "client_message", sender, nick, clean)
	if DisplayServer.get_name() != "headless":
		message_received.emit(sender, nick, clean)


## Не больше RATE_LIMIT сообщений за RATE_WINDOW_MSEC от одного игрока.
func _allowed(peer_id: int) -> bool:
	var now := Time.get_ticks_msec()
	var times: Array = _recent.get(peer_id, [])
	while not times.is_empty() and now - int(times[0]) > RATE_WINDOW_MSEC:
		times.pop_front()
	if times.size() >= RATE_LIMIT:
		_recent[peer_id] = times
		return false
	times.append(now)
	_recent[peer_id] = times
	return true


func _clean_text(text: String) -> String:
	return _strip_controls(text.substr(0, MAX_TEXT * 2)).strip_edges().substr(0, MAX_TEXT)


func _clean_nick(nick: String) -> String:
	return _strip_controls(nick.substr(0, MAX_NICK * 2)).strip_edges().substr(0, MAX_NICK)


## Убирает управляющие символы и невидимые знаки, которыми можно ломать вёрстку или переворачивать текст.
func _strip_controls(text: String) -> String:
	var result := ""
	for i in text.length():
		var code := text.unicode_at(i)
		if code < 32 or code == 127:
			continue
		if (code >= 0x200B and code <= 0x200F) or (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069):
			continue
		result += text.substr(i, 1)
	return result


func _on_peer_disconnected(peer_id: int) -> void:
	_nicks.erase(peer_id)
	_recent.erase(peer_id)
