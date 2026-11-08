extends Node
## Превращает файл скина (.glb или ZIP с OBJ, MTL и текстурами, например из BloxMesh)
## в «пакет скина»: модель режется на 6 частей тела (торс, голова, две руки, две ноги,
## как у R6), всё хранится в простых массивах. Пакет сжимается и передаётся другим игрокам.
##
##   import_file(path) -> Dictionary    пакет скина или {} (причина в last_error), вызывать с await
##   pack_to_bytes(pack) -> PackedByteArray
##   bytes_to_pack(data) -> Dictionary  проверенный пакет или {}
##   build_parts(pack) -> Dictionary    {часть: {"mesh": ArrayMesh, "pivot": Vector3}}

const SKIN_HEIGHT := 2.0
const MAX_FILE_BYTES := 40 * 1024 * 1024
const MAX_TRIANGLES := 120000
const MAX_VERTICES := 400000
const MAX_TEXTURES := 16
const MAX_MATERIALS := 64
const SEND_TEXTURE_SIDE := 512
const RECV_TEXTURE_SIDE := 1024
const MAX_PACK_BYTES := 8 * 1024 * 1024
const MAX_RAW_BYTES := 48 * 1024 * 1024
const PARSE_CHUNK := 3000
const GLB_YAW := PI  # модели glTF смотрят в +Z, а лицо игрока в Godot смотрит в -Z
const OBJ_YAW := 0.0  # модели Roblox (OBJ) смотрят в -Z; если скин идёт задом наперёд, поставь PI
const PROBE_OFFSET := 0.004  # на сколько «внутрь» грани сдвигается точка проверки части тела
const PART_NAMES := ["torso", "head", "arm_l", "arm_r", "leg_l", "leg_r"]

var last_error := ""


func _ready() -> void:
	add_to_group("skin_importer")


# ---------- чтение файла ----------

func import_file(path: String) -> Dictionary:
	last_error = ""
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		last_error = "Не удалось прочитать файл (%s)" % error_string(FileAccess.get_open_error())
		return {}
	if bytes.size() > MAX_FILE_BYTES:
		last_error = "Файл слишком большой (больше 40 МБ)"
		return {}
	var source := {}
	if bytes.size() > 4 and bytes.slice(0, 4).get_string_from_ascii() == "glTF":
		source = _read_glb(bytes)
	elif bytes.size() > 4 and bytes[0] == 0x50 and bytes[1] == 0x4B:
		source = await _read_zip(bytes)
	else:
		last_error = "Нужен файл .glb или ZIP с моделью .obj"
		return {}
	if source.is_empty():
		return {}
	var pack: Dictionary = await _make_pack(source)
	return pack


## .glb: загружаем сцену средствами Godot и собираем из неё треугольники.
func _read_glb(bytes: PackedByteArray) -> Dictionary:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		last_error = "Не удалось прочитать .glb: %s" % error_string(err)
		return {}
	var root := doc.generate_scene(state)
	if root == null:
		last_error = "В .glb нет сцены"
		return {}
	var surfaces: Array = []
	var materials: Array = []
	var images: Array = []
	var material_ids := {}  # материал -> индекс в materials
	var image_ids := {}     # текстура -> индекс в images
	var triangles := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _transform_to_root(mi, root)
		for s in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := mi.mesh.surface_get_arrays(s)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if pos.is_empty():
				continue
			var idx := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				idx = arrays[Mesh.ARRAY_INDEX]
			if idx.is_empty():
				idx.resize(pos.size())
				for i in pos.size():
					idx[i] = i
			var nrm := PackedVector3Array()
			if arrays[Mesh.ARRAY_NORMAL] != null:
				nrm = arrays[Mesh.ARRAY_NORMAL]
			var uv := PackedVector2Array()
			if arrays[Mesh.ARRAY_TEX_UV] != null:
				uv = arrays[Mesh.ARRAY_TEX_UV]
			triangles += idx.size() / 3
			if triangles > MAX_TRIANGLES:
				root.free()
				last_error = "Слишком много полигонов (больше %d)" % MAX_TRIANGLES
				return {}
			# Переносим вершины в общее пространство модели.
			var moved := PackedVector3Array()
			moved.resize(pos.size())
			for i in pos.size():
				moved[i] = xf * pos[i]
			var moved_normals := PackedVector3Array()
			if nrm.size() == pos.size():
				moved_normals.resize(nrm.size())
				for i in nrm.size():
					moved_normals[i] = (xf.basis * nrm[i]).normalized()
			var mat_index := _glb_material(mi.get_active_material(s), materials, images, material_ids, image_ids)
			surfaces.append({"pos": moved, "nrm": moved_normals, "uv": uv, "idx": idx, "mat": mat_index})
	root.free()
	if surfaces.is_empty():
		last_error = "В .glb не найдено моделей"
		return {}
	return {"surfaces": surfaces, "materials": materials, "images": images, "yaw": GLB_YAW}


func _transform_to_root(node: Node3D, root: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D:
			result = (current as Node3D).transform * result
		current = current.get_parent()
	return result


func _glb_material(material: Material, materials: Array, images: Array, material_ids: Dictionary, image_ids: Dictionary) -> int:
	if material != null and material_ids.has(material):
		return material_ids[material]
	var info := {"color": Color.WHITE, "tex": -1}
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		info["color"] = base.albedo_color
		var tex := base.albedo_texture
		if tex != null:
			if image_ids.has(tex):
				info["tex"] = image_ids[tex]
			else:
				var img := tex.get_image()
				if img != null:
					if img.is_compressed():
						img.decompress()
					images.append(img)
					image_ids[tex] = images.size() - 1
					info["tex"] = images.size() - 1
	materials.append(info)
	var index := materials.size() - 1
	if material != null:
		material_ids[material] = index
	return index


## ZIP (например, из BloxMesh): внутри .obj, .mtl и картинки текстур.
func _read_zip(bytes: PackedByteArray) -> Dictionary:
	# ZIPReader открывает только файлы, поэтому сначала сохраняем архив во временный файл.
	var tmp_path := "user://skin_import.zip"
	var out := FileAccess.open(tmp_path, FileAccess.WRITE)
	if out == null:
		last_error = "Не удалось подготовить архив"
		return {}
	out.store_buffer(bytes)
	out.close()
	var zip := ZIPReader.new()
	if zip.open(tmp_path) != OK:
		last_error = "Не удалось открыть ZIP"
		return {}
	var obj_entry := ""
	var mtl_entry := ""
	var by_name := {}  # имя файла без папок, в нижнем регистре -> путь в архиве
	var by_stem := {}  # то же, но без расширения (только для картинок)
	for entry in zip.get_files():
		var low := String(entry).to_lower()
		var file_name := low.get_file()
		by_name[file_name] = entry
		if file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg") or file_name.ends_with(".webp"):
			by_stem[file_name.get_basename()] = entry
		if obj_entry == "" and file_name.ends_with(".obj"):
			obj_entry = entry
		elif mtl_entry == "" and file_name.ends_with(".mtl"):
			mtl_entry = entry
	if obj_entry == "":
		zip.close()
		last_error = "В архиве нет файла .obj"
		return {}
	var obj_text := zip.read_file(obj_entry).get_string_from_utf8()
	var mtl_text := ""
	if mtl_entry != "":
		mtl_text = zip.read_file(mtl_entry).get_string_from_utf8()
	var mats := _parse_mtl(mtl_text)
	var images: Array = []
	var image_ids := {}  # путь в архиве -> индекс в images
	for mat_name in mats:
		var tex_file: String = mats[mat_name]["tex"]
		if tex_file == "":
			continue
		var low_name := tex_file.to_lower()
		var entry_path := ""
		if by_name.has(low_name):
			entry_path = by_name[low_name]
		elif by_stem.has(low_name.get_basename()):
			entry_path = by_stem[low_name.get_basename()]
		if entry_path == "":
			continue
		if not image_ids.has(entry_path):
			var img := _decode_image(zip.read_file(entry_path))
			if img == null:
				continue
			images.append(img)
			image_ids[entry_path] = images.size() - 1
		mats[mat_name]["tex_index"] = image_ids[entry_path]
	zip.close()
	var parsed: Dictionary = await _parse_obj(obj_text)
	var source: Dictionary = await _obj_to_source(parsed, mats, images)
	return source


func _decode_image(bytes: PackedByteArray) -> Image:
	if bytes.is_empty():
		return null
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes)
	if err != OK:
		err = img.load_jpg_from_buffer(bytes)
	if err != OK:
		err = img.load_webp_from_buffer(bytes)
	if err != OK:
		return null
	return img


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


## OBJ -> общий вид: по одной поверхности на материал, вершины без повторов.
func _obj_to_source(parsed: Dictionary, mats: Dictionary, images: Array) -> Dictionary:
	var verts: PackedVector3Array = parsed["verts"]
	var uvs: PackedVector2Array = parsed["uvs"]
	var norms: PackedVector3Array = parsed["norms"]
	var cv: PackedInt32Array = parsed["cv"]
	var ct: PackedInt32Array = parsed["ct"]
	var cn: PackedInt32Array = parsed["cn"]
	var tri_mat: PackedInt32Array = parsed["tri_mat"]
	var mat_names: Array = parsed["mat_names"]
	if verts.is_empty() or tri_mat.is_empty():
		last_error = "В файле .obj нет геометрии"
		return {}
	if tri_mat.size() > MAX_TRIANGLES:
		last_error = "Слишком много полигонов (%d, максимум %d)" % [tri_mat.size(), MAX_TRIANGLES]
		return {}
	var materials: Array = []
	for mat_name in mat_names:
		var info: Dictionary = mats.get(mat_name, {})
		materials.append({"color": info.get("color", Color.WHITE), "tex": info.get("tex_index", -1)})
	var by_mat := {}  # индекс материала -> поверхность
	for t in tri_mat.size():
		if t % 4000 == 0:
			await get_tree().process_frame
		var ia := cv[t * 3]
		var ib := cv[t * 3 + 1]
		var ic := cv[t * 3 + 2]
		if ia < 0 or ib < 0 or ic < 0 or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
			continue
		var face_normal := (verts[ib] - verts[ia]).cross(verts[ic] - verts[ia]).normalized()
		var surface: Dictionary = by_mat.get(tri_mat[t], {})
		if surface.is_empty():
			surface = {"pos": PackedVector3Array(), "nrm": PackedVector3Array(), "uv": PackedVector2Array(), "idx": PackedInt32Array(), "lookup": {}, "mat": tri_mat[t]}
			by_mat[tri_mat[t]] = surface
		var lookup: Dictionary = surface["lookup"]
		for k in 3:
			var base := t * 3 + k
			var key := Vector3i(cv[base], ct[base], cn[base])
			if lookup.has(key):
				surface["idx"].append(lookup[key])
			else:
				var new_index: int = surface["pos"].size()
				lookup[key] = new_index
				surface["pos"].append(verts[cv[base]])
				surface["nrm"].append(_normal_at(norms, cn[base], face_normal))
				surface["uv"].append(_uv_at(uvs, ct[base]))
				surface["idx"].append(new_index)
	var surfaces: Array = []
	for key in by_mat:
		var s: Dictionary = by_mat[key]
		surfaces.append({"pos": s["pos"], "nrm": s["nrm"], "uv": s["uv"], "idx": s["idx"], "mat": s["mat"]})
	if surfaces.is_empty():
		last_error = "В файле .obj нет корректных полигонов"
		return {}
	return {"surfaces": surfaces, "materials": materials, "images": images, "yaw": OBJ_YAW}


# ---------- нарезка на части тела ----------

func _make_pack(source: Dictionary) -> Dictionary:
	var surfaces: Array = source["surfaces"]
	var materials: Array = source["materials"]
	var images: Array = source["images"]

	# Нормализация: ноги на y = 0, центр по x и z, высота SKIN_HEIGHT.
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for surf in surfaces:
		var positions: PackedVector3Array = surf["pos"]
		for v in positions:
			lo = lo.min(v)
			hi = hi.max(v)
	var height := hi.y - lo.y
	if height < 0.0001:
		last_error = "Модель плоская или пустая"
		return {}
	var k := SKIN_HEIGHT / height
	var origin := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)

	# Раскладываем треугольники по частям тела и материалам. Вершины внутри корзины не повторяются.
	var buckets := {}  # часть -> {материал -> корзина}
	var counter := 0
	for si in surfaces.size():
		var surf: Dictionary = surfaces[si]
		var pos: PackedVector3Array = surf["pos"]
		var nrm: PackedVector3Array = surf["nrm"]
		var uv: PackedVector2Array = surf["uv"]
		var idx: PackedInt32Array = surf["idx"]
		var mat: int = surf["mat"]
		var has_normals := nrm.size() == pos.size()
		var has_uv := uv.size() == pos.size()
		var tv := PackedVector3Array()
		tv.resize(pos.size())
		for i in pos.size():
			tv[i] = (pos[i] - origin) * k
		for t in idx.size() / 3:
			counter += 1
			if counter % 4000 == 0:
				await get_tree().process_frame
			var ia := idx[t * 3]
			var ib := idx[t * 3 + 1]
			var ic := idx[t * 3 + 2]
			if ia < 0 or ib < 0 or ic < 0 or ia >= tv.size() or ib >= tv.size() or ic >= tv.size():
				continue
			var pa := tv[ia]
			var pb := tv[ib]
			var pc := tv[ic]
			var face_normal := (pb - pa).cross(pc - pa).normalized()
			# Точку проверяем чуть «внутри» грани: так грани, лежащие ровно на границе частей
			# (низ торса и верх ноги и т.п.), достаются той части, которой они принадлежат.
			var probe := (pa + pb + pc) / 3.0 - face_normal * PROBE_OFFSET
			var part := _classify(probe)
			var by_mat: Dictionary = buckets.get(part, {})
			if by_mat.is_empty():
				buckets[part] = by_mat
			var bucket: Dictionary = by_mat.get(mat, {})
			if bucket.is_empty():
				bucket = {"pos": PackedVector3Array(), "nrm": PackedVector3Array(), "uv": PackedVector2Array(), "idx": PackedInt32Array(), "lookup": {}}
				by_mat[mat] = bucket
			var lookup: Dictionary = bucket["lookup"]
			# Порядок вершин меняем на обратный: в Godot лицевые грани идут по часовой стрелке.
			for corner in [0, 2, 1]:
				var vi: int = idx[t * 3 + corner]
				var key: int = si * 16777216 + vi
				if lookup.has(key):
					bucket["idx"].append(lookup[key])
				else:
					var new_index: int = bucket["pos"].size()
					lookup[key] = new_index
					bucket["pos"].append(tv[vi])
					bucket["nrm"].append(nrm[vi] if has_normals else face_normal)
					bucket["uv"].append(uv[vi] if has_uv else Vector2.ZERO)
					bucket["idx"].append(new_index)
	if buckets.is_empty():
		last_error = "В модели нет корректных полигонов"
		return {}

	# Собираем пакет: части, материалы и текстуры (картинки уменьшаем и кодируем в PNG).
	var out_materials: Array = []
	var out_textures: Array = []
	var mat_map := {}  # старый индекс материала -> новый
	var tex_map := {}  # старый индекс текстуры -> новый
	var out_parts := {}
	for part_name in buckets:
		var out_surfaces: Array = []
		var sum := Vector3.ZERO
		var count := 0
		var top := -INF
		var bottom := INF
		for mat_old in buckets[part_name]:
			var b: Dictionary = buckets[part_name][mat_old]
			if not mat_map.has(mat_old):
				mat_map[mat_old] = out_materials.size()
				var info := {"color": Color.WHITE, "tex": -1}
				if mat_old >= 0 and mat_old < materials.size():
					info = materials[mat_old]
				var tex_old: int = info["tex"]
				var tex_new := -1
				if tex_old >= 0 and tex_old < images.size() and out_textures.size() < MAX_TEXTURES:
					if not tex_map.has(tex_old):
						tex_map[tex_old] = out_textures.size()
						out_textures.append(_encode_texture(images[tex_old]))
					tex_new = tex_map[tex_old]
				elif tex_map.has(tex_old):
					tex_new = tex_map[tex_old]
				out_materials.append({"color": info["color"], "tex": tex_new})
			out_surfaces.append({"pos": b["pos"], "nrm": b["nrm"], "uv": b["uv"], "idx": b["idx"], "mat": mat_map[mat_old]})
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
		out_parts[part_name] = {"pivot": pivot, "surfaces": out_surfaces}
	var pack := {
		"v": 1,
		"yaw": float(source.get("yaw", 0.0)),
		"parts": out_parts,
		"materials": out_materials,
		"textures": out_textures,
	}
	if not _valid_pack(pack):
		last_error = "Модель слишком сложная (максимум %d полигонов)" % MAX_TRIANGLES
		return {}
	return pack


## Какой части тела (как у R6) принадлежит точка. Модель уже нормализована:
## ноги на y = 0, высота SKIN_HEIGHT, центр по x = 0.
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


func _encode_texture(source: Image) -> PackedByteArray:
	var img := source
	if img.is_compressed():
		img.decompress()
	var longest := maxi(img.get_width(), img.get_height())
	if longest > SEND_TEXTURE_SIDE:
		var f := float(SEND_TEXTURE_SIDE) / float(longest)
		img.resize(maxi(1, int(img.get_width() * f)), maxi(1, int(img.get_height() * f)), Image.INTERPOLATE_BILINEAR)
	img.convert(Image.FORMAT_RGB8)
	return img.save_png_to_buffer()


# ---------- упаковка и проверка ----------

func pack_to_bytes(pack: Dictionary) -> PackedByteArray:
	var raw := var_to_bytes(pack)
	var compressed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(compressed)
	return out


## Принимает байты от другого игрока. Всё проверяется: размеры, индексы, размеры картинок.
func bytes_to_pack(data: PackedByteArray) -> Dictionary:
	if data.size() < 8 or data.size() > MAX_PACK_BYTES:
		return {}
	var raw_size := data.decode_u32(0)
	if raw_size < 16 or raw_size > MAX_RAW_BYTES:
		return {}
	var raw := data.slice(4).decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return {}
	var value = bytes_to_var(raw)
	if not (value is Dictionary) or not _valid_pack(value):
		return {}
	return value


func _valid_pack(pack: Dictionary) -> bool:
	if not (pack.get("parts") is Dictionary) or not (pack.get("materials") is Array) or not (pack.get("textures") is Array):
		return false
	var textures: Array = pack["textures"]
	var materials: Array = pack["materials"]
	if textures.size() > MAX_TEXTURES or materials.size() > MAX_MATERIALS:
		return false
	for png in textures:
		if not (png is PackedByteArray) or not _png_ok(png):
			return false
	for m in materials:
		if not (m is Dictionary) or not (m.get("color") is Color) or not (m.get("tex") is int):
			return false
		if m["tex"] >= textures.size():
			return false
	var vertices := 0
	var indices := 0
	var parts: Dictionary = pack["parts"]
	for part_name in parts:
		if not PART_NAMES.has(part_name):
			return false
		var info = parts[part_name]
		if not (info is Dictionary) or not (info.get("pivot") is Vector3) or not (info.get("surfaces") is Array):
			return false
		for s in info["surfaces"]:
			if not (s is Dictionary):
				return false
			var pos = s.get("pos")
			var nrm = s.get("nrm")
			var uv = s.get("uv")
			var idx = s.get("idx")
			if not (pos is PackedVector3Array) or not (nrm is PackedVector3Array) or not (uv is PackedVector2Array) or not (idx is PackedInt32Array):
				return false
			if pos.is_empty() or nrm.size() != pos.size() or uv.size() != pos.size() or idx.size() % 3 != 0:
				return false
			if not (s.get("mat") is int) or s["mat"] < 0 or s["mat"] >= materials.size():
				return false
			vertices += pos.size()
			indices += idx.size()
			if vertices > MAX_VERTICES or indices > MAX_TRIANGLES * 3:
				return false
			for i in idx:
				if i < 0 or i >= pos.size():
					return false
	return true


func _png_ok(png: PackedByteArray) -> bool:
	if png.size() < 33 or png.size() > MAX_PACK_BYTES:
		return false
	var signature := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
	if png.slice(0, 8) != signature:
		return false
	var w := (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19]
	var h := (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23]
	return w > 0 and h > 0 and w <= RECV_TEXTURE_SIDE and h <= RECV_TEXTURE_SIDE


# ---------- сборка сеток для показа ----------

func build_parts(pack: Dictionary) -> Dictionary:
	var textures: Array = []
	for png in pack["textures"]:
		var img := Image.new()
		if img.load_png_from_buffer(png) == OK:
			img.generate_mipmaps()
			textures.append(ImageTexture.create_from_image(img))
		else:
			textures.append(null)
	var materials: Array = []
	for m in pack["materials"]:
		var material := StandardMaterial3D.new()
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.albedo_color = m["color"]
		var tex_index: int = m["tex"]
		if tex_index >= 0 and tex_index < textures.size() and textures[tex_index] != null:
			material.albedo_texture = textures[tex_index]
			material.albedo_color = Color.WHITE
		materials.append(material)
	var result := {}
	for part_name in pack["parts"]:
		var info: Dictionary = pack["parts"][part_name]
		var mesh := ArrayMesh.new()
		for s in info["surfaces"]:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = s["pos"]
			arrays[Mesh.ARRAY_NORMAL] = s["nrm"]
			arrays[Mesh.ARRAY_TEX_UV] = s["uv"]
			arrays[Mesh.ARRAY_INDEX] = s["idx"]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, materials[s["mat"]])
		result[part_name] = {"mesh": mesh, "pivot": info["pivot"]}
	return result
