extends Control
## Сенсорное управление.
## Левая половина экрана: плавающий джойстик (движение). Значение в move_vector (от -1 до 1).
## Правая половина экрана: палец вращает камеру. Сдвиг накапливается в look_delta,
## игрок забирает его методом consume_look().

const RADIUS := 110.0
const LOOK_TOP_MARGIN := 110.0  # верхнюю полосу справа занимает кнопка «Скин»

var move_vector := Vector2.ZERO
var look_delta := Vector2.ZERO

## Пока открыт ввод в чате, сенсорное управление выключено.
var enabled := true:
	set(value):
		enabled = value
		if not enabled:
			_release()
			_look_index = -1
			look_delta = Vector2.ZERO

var _touch_index := -1
var _origin := Vector2.ZERO
var _current := Vector2.ZERO
var _look_index := -1


func _ready() -> void:
	add_to_group("touch_controls")


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_release()
		_look_index = -1


## Сколько пикселей палец сдвинулся по правой половине экрана с прошлого вызова.
func consume_look() -> Vector2:
	var result := look_delta
	look_delta = Vector2.ZERO
	return result


func _input(event: InputEvent) -> void:
	if not enabled or not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if touch.position.x < size.x * 0.5:
				if _touch_index == -1:
					_touch_index = touch.index
					_origin = touch.position
					_current = touch.position
			elif _look_index == -1 and touch.position.y > LOOK_TOP_MARGIN:
				_look_index = touch.index
		elif touch.index == _touch_index:
			_release()
		elif touch.index == _look_index:
			_look_index = -1
		queue_redraw()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _touch_index:
			_current = drag.position
			move_vector = (_current - _origin).limit_length(RADIUS) / RADIUS
			queue_redraw()
		elif drag.index == _look_index:
			look_delta += drag.relative


func _release() -> void:
	_touch_index = -1
	move_vector = Vector2.ZERO
	queue_redraw()


func _draw() -> void:
	if _touch_index == -1:
		return
	draw_circle(_origin, RADIUS, Color(1, 1, 1, 0.15))
	draw_circle(_origin + (_current - _origin).limit_length(RADIUS), 42.0, Color(1, 1, 1, 0.45))
