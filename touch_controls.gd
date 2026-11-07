extends Control
## Простой плавающий джойстик: касание в левой половине экрана задаёт центр,
## смещение пальца - направление. Значение лежит в move_vector (от -1 до 1).

const RADIUS := 110.0

var move_vector := Vector2.ZERO

var _touch_index := -1
var _origin := Vector2.ZERO
var _current := Vector2.ZERO


func _ready() -> void:
	add_to_group("touch_controls")


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_release()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _touch_index == -1 and touch.position.x < size.x * 0.5:
				_touch_index = touch.index
				_origin = touch.position
				_current = touch.position
		elif touch.index == _touch_index:
			_release()
		queue_redraw()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _touch_index:
			_current = drag.position
			move_vector = (_current - _origin).limit_length(RADIUS) / RADIUS
			queue_redraw()


func _release() -> void:
	_touch_index = -1
	move_vector = Vector2.ZERO
	queue_redraw()


func _draw() -> void:
	if _touch_index == -1:
		return
	draw_circle(_origin, RADIUS, Color(1, 1, 1, 0.15))
	draw_circle(_origin + (_current - _origin).limit_length(RADIUS), 42.0, Color(1, 1, 1, 0.45))
