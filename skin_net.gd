extends Node
## Передача скинов между игроками через сервер. Сервер только хранит и пересылает байты,
## а проверяет и разбирает скин каждый клиент сам.

signal skin_ready(owner_id: int)

const CHUNK_SIZE := 16384
const CHUNKS_PER_FRAME := 4
const MAX_CHUNKS := 600
const MAX_PACK_BYTES := 8 * 1024 * 1024
const MAX_STORED := 32

var _skins := {}     # id игрока -> проверенный пакет скина (у клиентов)
var _stored := {}    # id игрока -> байты пакета (у сервера)
var _incoming := {}  # id -> {"total": int, "chunks": Dictionary, "size": int}


func _ready() -> void:
	add_to_group("skin_net")
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func get_skin(owner_id: int) -> Dictionary:
	return _skins.get(owner_id, {})


## Свой скин: применяем у себя сразу и отправляем остальным через сервер.
func submit(owner_id: int, pack: Dictionary, data: PackedByteArray) -> void:
	_skins[owner_id] = pack
	skin_ready.emit(owner_id)
	if multiplayer.is_server():
		_store_and_broadcast(owner_id, data)
		return
	var total := ceili(float(data.size()) / CHUNK_SIZE)
	for i in total:
		rpc_id(1, "server_receive_chunk", i, total, data.slice(i * CHUNK_SIZE, mini((i + 1) * CHUNK_SIZE, data.size())))
		if i % CHUNKS_PER_FRAME == CHUNKS_PER_FRAME - 1:
			await get_tree().process_frame


## Новый игрок просит у сервера скины тех, кто уже на острове.
func request_all() -> void:
	if not multiplayer.is_server():
		rpc_id(1, "server_send_all")


@rpc("any_peer", "call_remote", "reliable")
func server_receive_chunk(index: int, total: int, data: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var full := _add_chunk(sender, index, total, data)
	if full.is_empty():
		return
	_store_and_broadcast(sender, full)


@rpc("any_peer", "call_remote", "reliable")
func server_send_all() -> void:
	if not multiplayer.is_server():
		return
	var requester := multiplayer.get_remote_sender_id()
	for owner_id in _stored:
		if owner_id != requester:
			_send_pack(requester, owner_id, _stored[owner_id])


@rpc("authority", "call_remote", "reliable")
func client_receive_chunk(owner_id: int, index: int, total: int, data: PackedByteArray) -> void:
	var full := _add_chunk(owner_id, index, total, data)
	if full.is_empty():
		return
	_accept_pack(owner_id, full)


## Складывает кусочки; когда все на месте, возвращает собранные байты, иначе пустой массив.
func _add_chunk(key: int, index: int, total: int, data: PackedByteArray) -> PackedByteArray:
	if total <= 0 or total > MAX_CHUNKS or index < 0 or index >= total or data.size() > CHUNK_SIZE:
		return PackedByteArray()
	var entry: Dictionary = _incoming.get(key, {})
	if entry.is_empty() or entry["total"] != total or index == 0:
		entry = {"total": total, "chunks": {}, "size": 0}
		_incoming[key] = entry
	var chunks: Dictionary = entry["chunks"]
	if chunks.has(index):
		return PackedByteArray()
	chunks[index] = data
	entry["size"] += data.size()
	if entry["size"] > MAX_PACK_BYTES:
		_incoming.erase(key)
		return PackedByteArray()
	if chunks.size() < total:
		return PackedByteArray()
	_incoming.erase(key)
	var full := PackedByteArray()
	for i in total:
		full.append_array(chunks[i])
	return full


func _store_and_broadcast(owner_id: int, data: PackedByteArray) -> void:
	if not _stored.has(owner_id) and _stored.size() >= MAX_STORED:
		return
	_stored[owner_id] = data
	for peer in multiplayer.get_peers():
		if peer != owner_id:
			_send_pack(peer, owner_id, data)
	# Сервер с экраном (тест на телефоне) тоже показывает скины игроков.
	if owner_id != multiplayer.get_unique_id() and DisplayServer.get_name() != "headless":
		_accept_pack(owner_id, data)


func _send_pack(peer: int, owner_id: int, data: PackedByteArray) -> void:
	var total := ceili(float(data.size()) / CHUNK_SIZE)
	for i in total:
		if not multiplayer.get_peers().has(peer):
			return
		rpc_id(peer, "client_receive_chunk", owner_id, i, total, data.slice(i * CHUNK_SIZE, mini((i + 1) * CHUNK_SIZE, data.size())))
		if i % CHUNKS_PER_FRAME == CHUNKS_PER_FRAME - 1:
			await get_tree().process_frame


func _accept_pack(owner_id: int, data: PackedByteArray) -> void:
	var importer = get_tree().get_first_node_in_group("skin_importer")
	if importer == null:
		return
	var pack: Dictionary = importer.bytes_to_pack(data)
	if pack.is_empty():
		return
	_skins[owner_id] = pack
	skin_ready.emit(owner_id)


func _on_peer_disconnected(id: int) -> void:
	_incoming.erase(id)
	_skins.erase(id)
	if multiplayer.is_server():
		_stored.erase(id)
