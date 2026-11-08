extends CharacterBody3D
## Игрок. Имя узла = id владельца. Двигает персонажа только владелец,
## остальным позиция и поворот приходят через MultiplayerSynchronizer.
## Скин (части модели) приходит отдельно через SkinNet.

const SPEED := 6.0
const GRAVITY := 25.0
const TURN_SPEED := 12.0

var _controls: Node
var _skin: Node3D
var _pivots := {}
var _last_pos := Vector3.ZERO
var _speed := 0.0
var _phase := 0.0

@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _nose: MeshInstance3D = $Body/Nose
@onready var _camera: Camera3D = $Camera3D
@onready var _name_label: Label3D = $NameLabel


func _enter_tree() -> void:
	# Владелец игрока - тот, чей id записан в имени узла.
	set_multiplayer_authority(str(name).to_int())


func _ready() -> void:
	_name_label.text = "Игрок " + str(name)
	_paint(str(name).to_int())
	_last_pos = global_position
	if is_multiplayer_authority():
		_camera.make_current()
		_controls = get_tree().get_first_node_in_group("touch_controls")
	else:
		_camera.queue_free()
	# Серверу (без экрана) скины не нужны.
	if DisplayServer.get_name() != "headless":
		var net = get_tree().get_first_node_in_group("skin_net")
		if net != null:
			net.skin_ready.connect(_on_skin_ready)
		_load_skin()


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	var input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if _controls:
		input += _controls.get("move_vector")
	input = input.limit_length(1.0)

	# Палец вверх = от камеры (-Z).
	var direction := Vector3(input.x, 0.0, input.y)
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


## Анимация ходьбы как у R6: ноги и руки качаются в противофазе. Работает у всех игроков:
## скорость берётся из того, как меняется позиция.
func _process(delta: float) -> void:
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


func _set_swing(part: String, angle: float) -> void:
	if _pivots.has(part):
		(_pivots[part] as Node3D).rotation.x = angle


func _paint(id: int) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_hsv(float(id % 360) / 360.0, 0.65, 0.95)
	_mesh.material_override = material


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
