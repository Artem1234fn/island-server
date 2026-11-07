extends CharacterBody3D
## Игрок. Имя узла = id владельца. Двигает персонажа только владелец,
## остальным позиция и поворот приходят через MultiplayerSynchronizer.

const SPEED := 6.0
const GRAVITY := 25.0
const TURN_SPEED := 12.0

var _controls: Node

@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _camera: Camera3D = $Camera3D
@onready var _name_label: Label3D = $NameLabel


func _enter_tree() -> void:
	# Владелец игрока - тот, чей id записан в имени узла.
	set_multiplayer_authority(str(name).to_int())


func _ready() -> void:
	_name_label.text = "Игрок " + str(name)
	_paint(str(name).to_int())
	if is_multiplayer_authority():
		_camera.make_current()
		_controls = get_tree().get_first_node_in_group("touch_controls")
	else:
		_camera.queue_free()


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


func _paint(id: int) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_hsv(float(id % 360) / 360.0, 0.65, 0.95)
	_mesh.material_override = material
