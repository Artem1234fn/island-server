extends Node
## Скачивает 3D-аватар Roblox по нику и разрезает его на 6 частей тела (как у R6):
## торс, голова, две руки, две ноги. Из частей игрок собирает скелет и анимирует его.
##
## Используется неофициальный публичный эндпоинт thumbnails.roblox.com (avatar-3d),
## поэтому в будущем Roblox может его изменить.
##
## Методы (вызывать с await):
##   resolve_user_id(username) -> int     0, если не найден (причина в last_error)
##   get_avatar(user_id) -> Dictionary    {} при ошибке (причина в last_error)

const SKIN_HEIGHT := 2.0     # высота скина в единицах Godot
const PARSE_CHUNK := 3000    # сколько строк OBJ разбирать за один кадр
const PENDING_RETRIES := 12  # сколько раз ждать, пока Roblox соберёт модель

var last_error := ""

var _cache := {}    # user_id -> готовый аватар
var _loading := {}  # user_id -> true, пока аватар качается
var _hash_re := RegEx.new()


func _init() -> void:
	_hash_re.compile("^[A-Za-z0-9_-]+$")


func _ready() -> void:
	add_to_group("avatar_loader")


func resolve_user_id(username: String) -> int:
	last_error = ""
	username = username.strip_edges()
	if username.length() < 3 or username.length() > 20:
		last_error = "Ник Roblox должен быть от 3 до 20 символов"
		return 0
	var body := JSON.stringify({"usernames": [username], "excludeBannedUsers": true})
	var headers := PackedStringArray(["Content-Type: application/json"])
	var data = await _request_json("https://users.roblox.com/v1/usernames/users", HTTPClient.METHOD_POST, headers, body)
	if not (data is Dictionary) or not data.has("data"):
		last_error = "Не удалось связаться с Roblox"
		return 0
	var found: Array = data["data"]
	if found.is_empty():
		last_error = "Игрок с таким ником не найден"
		return 0
	return int(found[0].get("id", 0))


func get_avatar(user_id: int) -> Dictionary:
	last_error = ""
	if _cache.has(user_id):
		return _cache[user_id]
	# Если этот аватар уже качается (например, он надет у двух игроков), ждём.
	while _loading.has(user_id):
		await get_tree().create_timer(0.25).timeout
		if _cache.has(user_id):
			return _cache[user_id]
	_loading[user_id] = true
	var avatar: Dictionary = await _download_avatar(user_id)
	_loading.erase(user_id)
	if not avatar.is_empty():
		_cache[user_id] = avatar
	return avatar


func _download_avatar(user_id: int) -> Dictionary:
	# 1) Ссылка на описание 3D-модели. Пока Roblox её готовит, состояние Pending.
	var info = null
	for _i in PENDING_RETRIES:
		var meta = await _request_json("https://thumbnails.roblox.com/v1/users/avatar-3d?userId=%d" % user_id)
		if not (meta is Dictionary):
			last_error = "Roblox не отвечает"
			return {}
		var state := str(meta.get("state", ""))
		if state == "Completed" and meta.get("imageUrl") != null:
			info = await _request_json(str(meta["imageUrl"]))
			break
		if state != "Pending":
			last_error = "Roblox не отдал 3D-модель этого аватара (%s)" % state
			return {}
		await get_tree().create_timer(1.5).timeout
	if not (info is Dictionary) or not info.has("obj") or not info.has("mtl"):
		last_error = "Не удалось получить описание 3D-модели"
		return {}

	# 2) Файлы модели.
	var obj_file := str(info["obj"])
	var mtl_file := str(info["mtl"])
	if not _valid_hash(obj_file) or not _valid_hash(mtl_file):
		last_error = "Roblox вернул странные имена файлов"
		return {}
	var obj_bytes: PackedByteArray = await _download(obj_file)
	var mtl_bytes: PackedByteArray = await _download(mtl_file)
	if obj_bytes.is_empty():
		last_error = "Не удалось скачать модель аватара"
		return {}
	var mats := _parse_mtl(mtl_bytes.get_string_from_utf8())

	# 3) Текстуры, которые нужны материалам.
	var textures := {}
	for mat_name in mats:
		var tex_name: String = mats[mat_name]["tex"]
		if tex_name == "" or textures.has(tex_name) or not _valid_hash(tex_name):
			continue
		var tex_bytes: PackedByteArray = await _download(tex_name)
		if tex_bytes.is_empty():
			continue
		var tex := _load_texture(tex_bytes)
		if tex != null:
			textures[tex_name] = tex

	# 4) Разбор модели и нарезка на части тела.
	var obj: Dictionary = await _parse_obj(obj_bytes.get_string_from_utf8())
	var parts: Dictionary = await _build_parts(obj, mats, textures)
	if parts.is_empty():
		last_error = "Не удалось разобрать модель аватара"
		return {}
	return {"parts": parts}


# ---------- сеть ----------

func _request(url: String, method: HTTPClient.Method = HTTPClient.METHOD_GET, headers: PackedStringArray = PackedStringArray(), body: String = "") -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 30.0
	add_child(http)
	var err := http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "body": PackedByteArray()}
	var result: Array = await http.request_completed
	http.queue_free()
	var code: int = result[1]
	var ok: bool = result[0] == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	return {"ok": ok, "code": code, "body": result[3]}


func _request_json(url: String, method: HTTPClient.Method = HTTPClient.METHOD_GET, headers: PackedStringArray = PackedStringArray(), body: String = "") -> Variant:
	var res: Dictionary = await _request(url, method, headers, body)
	if not res["ok"]:
		return null
	var text: String = (res["body"] as PackedByteArray).get_string_from_utf8()
	return JSON.parse_string(text)


func _download(file_hash: String) -> PackedByteArray:
	for url in _cdn_urls(file_hash):
		var res: Dictionary = await _request(url)
		if res["ok"]:
			return res["body"]
	return PackedByteArray()


## Файлы Roblox лежат на серверах t0..t7; нужный номер считается по имени файла.
## Если формула вдруг изменится, остальные серверы перебираются по очереди.
func _cdn_urls(file_hash: String) -> PackedStringArray:
	var x := 31
	for i in file_hash.length():
		x ^= file_hash.unicode_at(i)
	var first := x % 8
	var urls := PackedStringArray()
	urls.append("https://t%d.rbxcdn.com/%s" % [first, file_hash])
	for n in 8:
		if n != first:
			urls.append("https://t%d.rbxcdn.com/%s" % [n, file_hash])
	return urls


func _valid_hash(value: String) -> bool:
	return _hash_re.search(value) != null


# ---------- разбор файлов ----------

func _parse_mtl(text: String) -> Dictionary:
	# имя материала -> {"color": Color, "tex": имя файла текстуры или ""}
	var mats := {}
	var current := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("newmtl "):
			current = line.substr(7).strip_edges()
			mats[current] = {"color": Color.WHITE, "tex": ""}
		elif current != "" and line.begins_with("Kd "):
			var p := line.split(" ", false)
			if p.size() >= 4:
				mats[current]["color"] = Color(float(p[1]), float(p[2]), float(p[3]))
		elif current != "" and line.begins_with("map_Kd "):
			var tex_name := line.substr(7).strip_edges()
			mats[current]["tex"] = tex_name.get_file()
	return mats


func _parse_obj(text: String) -> Dictionary:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var cv := PackedInt32Array()
	var ct := PackedInt32Array()
	var cn := PackedInt32Array()
	var tri_mat := PackedInt32Array()
	var mat_names: Array = ["__default__"]
	var cur_mat := 0
	var counter := 0
	for raw in text.split("\n"):
		counter += 1
		if counter % PARSE_CHUNK == 0:
			await get_tree().process_frame
		if raw.begins_with("v "):
			var p := raw.split(" ", false)
			if p.size() >= 4:
				verts.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif raw.begins_with("vt "):
			var p := raw.split(" ", false)
			if p.size() >= 3:
				uvs.append(Vector2(float(p[1]), float(p[2])))
		elif raw.begins_with("vn "):
			var p := raw.split(" ", false)
			if p.size() >= 4:
				norms.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
		elif raw.begins_with("usemtl "):
			var m := raw.substr(7).strip_edges()
			cur_mat = mat_names.find(m)
			if cur_mat == -1:
				mat_names.append(m)
				cur_mat = mat_names.size() - 1
		elif raw.begins_with("f "):
			var p := raw.split(" ", false)
			var corners := []
			for i in range(1, p.size()):
				corners.append(_parse_corner(p[i]))
			# Многоугольник превращаем в веер треугольников.
			for i in range(1, corners.size() - 1):
				for c in [corners[0], corners[i], corners[i + 1]]:
					cv.append(c.x)
					ct.append(c.y)
					cn.append(c.z)
				tri_mat.append(cur_mat)
	return {
		"verts": verts, "uvs": uvs, "norms": norms,
		"cv": cv, "ct": ct, "cn": cn,
		"tri_mat": tri_mat, "mat_names": mat_names,
	}


func _parse_corner(token: String) -> Vector3i:
	# "v", "v/t", "v//n" или "v/t/n"; индексы в OBJ начинаются с 1.
	var f := token.split("/")
	var v := int(f[0]) - 1
	var t := -1
	var n := -1
	if f.size() > 1 and f[1] != "":
		t = int(f[1]) - 1
	if f.size() > 2 and f[2] != "":
		n = int(f[2]) - 1
	return Vector3i(v, t, n)


# ---------- сборка частей тела ----------

func _build_parts(obj: Dictionary, mats: Dictionary, textures: Dictionary) -> Dictionary:
	var verts: PackedVector3Array = obj["verts"]
	var uvs: PackedVector2Array = obj["uvs"]
	var norms: PackedVector3Array = obj["norms"]
	var cv: PackedInt32Array = obj["cv"]
	var ct: PackedInt32Array = obj["ct"]
	var cn: PackedInt32Array = obj["cn"]
	var tri_mat: PackedInt32Array = obj["tri_mat"]
	var mat_names: Array = obj["mat_names"]
	if verts.is_empty() or tri_mat.is_empty():
		return {}

	# Нормализация: ноги на y = 0, центр по x и z, высота SKIN_HEIGHT.
	var lo := verts[0]
	var hi := verts[0]
	for v in verts:
		lo = lo.min(v)
		hi = hi.max(v)
	var height := hi.y - lo.y
	if height < 0.0001:
		return {}
	var k := SKIN_HEIGHT / height
	var origin := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	var tv := PackedVector3Array()
	tv.resize(verts.size())
	for i in verts.size():
		tv[i] = (verts[i] - origin) * k

	# Раскладываем треугольники по частям тела и материалам.
	var buckets := {}  # часть -> {индекс материала -> массивы вершин}
	for t in tri_mat.size():
		if t % 4000 == 0:
			await get_tree().process_frame
		var ia := cv[t * 3]
		var ib := cv[t * 3 + 1]
		var ic := cv[t * 3 + 2]
		if ia < 0 or ib < 0 or ic < 0 or ia >= tv.size() or ib >= tv.size() or ic >= tv.size():
			continue
		var pa := tv[ia]
		var pb := tv[ib]
		var pc := tv[ic]
		var face_normal := (pb - pa).cross(pc - pa).normalized()
		var part := _classify((pa + pb + pc) / 3.0)
		var by_mat: Dictionary = buckets.get(part, {})
		if by_mat.is_empty():
			buckets[part] = by_mat
		var bucket: Dictionary = by_mat.get(tri_mat[t], {})
		if bucket.is_empty():
			bucket = {"pos": PackedVector3Array(), "nrm": PackedVector3Array(), "uv": PackedVector2Array()}
			by_mat[tri_mat[t]] = bucket
		# Порядок вершин меняем на обратный: в Godot лицевые грани идут по часовой стрелке.
		for corner in [0, 2, 1]:
			var base: int = t * 3 + corner
			bucket["pos"].append(tv[cv[base]])
			bucket["nrm"].append(_normal_at(norms, cn[base], face_normal))
			bucket["uv"].append(_uv_at(uvs, ct[base]))

	# Из каждой части делаем сетку и считаем точку вращения (сустав).
	var material_cache := {}
	var result := {}
	for part_name in buckets:
		var mesh := ArrayMesh.new()
		var sum := Vector3.ZERO
		var count := 0
		var top := -INF
		var bottom := INF
		for mat_index in buckets[part_name]:
			var b: Dictionary = buckets[part_name][mat_index]
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = b["pos"]
			arrays[Mesh.ARRAY_NORMAL] = b["nrm"]
			arrays[Mesh.ARRAY_TEX_UV] = b["uv"]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _material_for(mat_index, mat_names, mats, textures, material_cache))
			for p in b["pos"]:
				sum += p
				count += 1
				top = maxf(top, p.y)
				bottom = minf(bottom, p.y)
			await get_tree().process_frame
		if count == 0:
			continue
		var mean := sum / float(count)
		var pivot := Vector3.ZERO
		match part_name:
			"head":
				pivot = Vector3(mean.x, bottom, mean.z)
			"arm_l", "arm_r", "leg_l", "leg_r":
				pivot = Vector3(mean.x, top, mean.z)
		result[part_name] = {"mesh": mesh, "pivot": pivot}
	return result


## Какой части тела (как у R6) принадлежит точка. Модель уже нормализована:
## ноги на y = 0, высота SKIN_HEIGHT, центр по x = 0, лицо смотрит в -Z.
func _classify(c: Vector3) -> String:
	var s := SKIN_HEIGHT
	if c.y >= 0.80 * s:
		if absf(c.x) > 0.30 * s:
			return "arm_r" if c.x > 0.0 else "arm_l"
		return "head"
	if c.y < 0.40 * s:
		return "leg_r" if c.x >= 0.0 else "leg_l"
	if c.x > 0.20 * s:
		return "arm_r"
	if c.x < -0.20 * s:
		return "arm_l"
	return "torso"


func _normal_at(norms: PackedVector3Array, idx: int, fallback: Vector3) -> Vector3:
	if idx >= 0 and idx < norms.size():
		return norms[idx]
	return fallback


func _uv_at(uvs: PackedVector2Array, idx: int) -> Vector2:
	if idx >= 0 and idx < uvs.size():
		return Vector2(uvs[idx].x, 1.0 - uvs[idx].y)
	return Vector2.ZERO


func _material_for(index: int, mat_names: Array, mats: Dictionary, textures: Dictionary, cache: Dictionary) -> StandardMaterial3D:
	if cache.has(index):
		return cache[index]
	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var info: Dictionary = mats.get(mat_names[index], {})
	material.albedo_color = info.get("color", Color.WHITE)
	var tex_name: String = info.get("tex", "")
	if tex_name != "" and textures.has(tex_name):
		material.albedo_texture = textures[tex_name]
		material.albedo_color = Color.WHITE
	# Карту прозрачности (map_d) намеренно не используем: из-за неё модель становится невидимой.
	cache[index] = material
	return material


func _load_texture(bytes: PackedByteArray) -> ImageTexture:
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes)
	if err != OK:
		err = img.load_jpg_from_buffer(bytes)
	if err != OK:
		err = img.load_webp_from_buffer(bytes)
	if err != OK:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
