extends VehicleBody3D

@export var STEER_SPEED: float = 1.4
@export var STEER_LIMIT: float = 0.6
@export var engine_force_value: float = 100

# --- Drift tuning (Space key / ui_select) ---
@export var DRIFT_BRAKE: float = 0.25
@export var DRIFT_STEER_LIMIT: float = 0.45
@export var DRIFT_STEER_SPEED: float = 0.8
@export var DRIFT_REAR_SLIP: float = 0.3

# --- Engine sound (pitch rises with speed) ---
@export var MIN_PITCH: float = 0.85
@export var MAX_PITCH: float = 8.0
@export var PITCH_AT_KMH: float = 205.0

# --- Top speed cap ---
@export var TOP_SPEED_KMH: float = 205.0

@onready var EngineSound: AudioStreamPlayer3D = $EngineSound
@onready var ScreechSound: AudioStreamPlayer3D = $ScreechSound   # add this node under your car

var steer_target: float = 0.0
var was_drifting: bool = false

func _ready() -> void:
	if EngineSound and not EngineSound.playing:
		EngineSound.play()

func _physics_process(delta: float) -> void:
	# Correct speed math
	var speed_mps: float = linear_velocity.length()      # meters/second
	var speed_kmh: float = speed_mps * 3.6               # km/h

	# HUD
	$Hud/speed.text = str(round(speed_kmh)) + "  KM/H"

	# Engine sound pitch
	if EngineSound:
		var pitch: float = lerpf(MIN_PITCH, MAX_PITCH, clamp(speed_kmh / PITCH_AT_KMH, 0.0, 1.0))
		EngineSound.pitch_scale = pitch

	# Extra downforce helper
	traction(speed_mps)

	# Steering
	steer_target = Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")
	var drifting := Input.is_action_pressed("ui_select")
	var steer_limit := (DRIFT_STEER_LIMIT if drifting else STEER_LIMIT)
	var steer_speed := (DRIFT_STEER_SPEED if drifting else STEER_SPEED)
	steering = move_toward(steering, steer_target * steer_limit, steer_speed * delta)

	# Throttle / Reverse
	var fwd_mps = transform.basis.x.x
	if Input.is_action_pressed("ui_down"):
		if speed_mps < 20.0 and speed_mps != 0.0:
			engine_force = clamp(engine_force_value * 3.0 / speed_mps, 0.0, 300.0)
		else:
			engine_force = engine_force_value
	else:
		engine_force = 0.0

	if Input.is_action_pressed("ui_up"):
		if fwd_mps >= -1.0:
			if speed_mps < 30.0 and speed_mps != 0.0:
				engine_force = -clamp(engine_force_value * 10.0 / speed_mps, 0.0, 300.0)
			else:
				engine_force = -engine_force_value
		else:
			brake = 1.0
	else:
		brake = 0.0

	# Drift behavior
	if drifting:
		brake = max(brake, DRIFT_BRAKE)
		$wheal2.wheel_friction_slip = DRIFT_REAR_SLIP
		$wheal3.wheel_friction_slip = DRIFT_REAR_SLIP

		# Play screech when drift STARTS
		if not was_drifting and ScreechSound:
			ScreechSound.pitch_scale = randf_range(0.9, 1.1)  # small pitch variation
			ScreechSound.play()
	else:
		$wheal2.wheel_friction_slip = 3.0
		$wheal3.wheel_friction_slip = 3.0

	was_drifting = drifting

# HARD top speed cap
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var v: Vector3 = state.linear_velocity
	var max_mps: float = TOP_SPEED_KMH / 3.6
	var s: float = v.length()
	if s > max_mps:
		state.linear_velocity = v * (max_mps / s)

func traction(speed_mps: float) -> void:
	apply_central_force(Vector3.DOWN * speed_mps)
