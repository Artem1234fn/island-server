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
		var chat = get_tree().get_first_node_in_group("chat_net")
		if chat != null:
			chat.nick_changed.connect(_on_nick_changed)
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
