extends Node3D

@export var car_path: NodePath
@export var start_gate_path: NodePath
@export var finish_gate_path: NodePath
@export var respawn_point_path: NodePath
@export var hud_timer_label_path: NodePath = ^"../Hud/Timer"

@export var auto_reset_on_finish: bool = true
@export var show_hundredths: bool = true
@export var settle_height: float = 0.25
@export var respawn_cooldown: float = 0.2   # ignore gates briefly after respawn

var _car: VehicleBody3D
var _start_gate: Area3D
var _finish_gate: Area3D
var _respawn_point: Node3D
var _label: Label

var _running := false
var _elapsed := 0.0
var _gate_ignore_until := 0.0  # timestamp (seconds) until which we ignore gate triggers

func _ready() -> void:
	_car = get_node_or_null(car_path) as VehicleBody3D
	_start_gate = get_node_or_null(start_gate_path) as Area3D
	_finish_gate = get_node_or_null(finish_gate_path) as Area3D
	_respawn_point = get_node_or_null(respawn_point_path) as Node3D
	_label = get_node_or_null(hud_timer_label_path) as Label

	if _label:
		_label.text = format_time(0.0)

	if _start_gate:
		_start_gate.body_entered.connect(_on_start_entered)
	if _finish_gate:
		_finish_gate.body_entered.connect(_on_finish_entered)

func _process(delta: float) -> void:
	if _running:
		_elapsed += delta
		if _label:
			_label.text = format_time(_elapsed)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		reset_run()

func reset_run() -> void:
	if _car == null:
		return

	var base_xform: Transform3D
	if _respawn_point:
		base_xform = _respawn_point.global_transform
	elif _start_gate:
		base_xform = _start_gate.global_transform
	else:
		return

	base_xform.origin += Vector3.UP * settle_height

	# 1) Teleport safely after current physics step
	_car.set_deferred("global_transform", base_xform)

	# 2) Clear velocities/forces shortly after teleport
	call_deferred("_clear_car_motion")

	# 3) Reset timer immediately
	_running = false
	_elapsed = 0.0
	if _label:
		_label.text = format_time(_elapsed)

	# 4) Ignore gates for a short window to prevent instant retrigger
	_gate_ignore_until = Time.get_unix_time_from_system() + respawn_cooldown

func _clear_car_motion() -> void:
	if _car == null: return
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.engine_force = 0.0
	_car.brake = 0.0
	_car.steering = 0.0
	_car.sleeping = false

func _on_start_entered(body: Node3D) -> void:
	if not _is_car(body): return
	if Time.get_unix_time_from_system() < _gate_ignore_until: return
	_running = true
	_elapsed = 0.0
	if _label:
		_label.text = format_time(_elapsed)

func _on_finish_entered(body: Node3D) -> void:
	if not _is_car(body): 
		return
	if Time.get_unix_time_from_system() < _gate_ignore_until: 
		return

	if _running:
		_running = false
		if _label:
			_label.text = format_time(_elapsed)


func _is_car(body: Node3D) -> bool:
	if body.is_in_group("car"): return true
	return body == _car

func format_time(t: float) -> String:
	var m := int(t) / 60
	var s := int(t) % 60
	if show_hundredths:
		var h := int(round((t - floor(t)) * 100.0))
		return "%02d:%02d.%02d" % [m, s, h]
	else:
		var d := int(round((t - floor(t)) * 10.0))
		return "%02d:%02d.%01d" % [m, s, d]
