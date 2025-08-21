extends VehicleBody3D

# ===== TUNING =====
@export var MAX_STEER: float = 0.55          # ~31° – nice for arcade
@export var STEER_SPEED: float = 9.0         # higher = snappier steering response
@export var ENGINE_POWER: float = 260.0      # forward accel strength
@export var BRAKE_POWER: float = 45.0        # normal braking
@export var REVERSE_POWER: float = 160.0     # reverse accel (lower feels better)

# Drift behavior (no handbrake)
@export var DRIFT_MIN_SPEED: float = 10.0    # m/s (~36 km/h) before drift can happen
@export var DRIFT_ANGLE_DEG: float = 12.0    # slip angle threshold to start drifting
@export var LATERAL_GRIP: float = 35.0       # base lateral resistance (bigger = more grip)
@export var LATERAL_GRIP_DRIFT: float = 12.0 # lateral resistance while drifting (lower = slides)

# Stability control
@export var YAW_STABILIZE: float = 0.7       # counters spin at low slip; lower during drift
@export var YAW_STABILIZE_DRIFT: float = 0.25

# Engine braking when off throttle
@export var ENGINE_BRAKE: float = 10.0

var _target_steer := 0.0
var _drifting := false

func _physics_process(delta: float) -> void:
	# --- Steering ---
	_target_steer = Input.get_axis("steer_right", "steer_left") * MAX_STEER
	steering = move_toward(steering, _target_steer, STEER_SPEED * delta)

	# --- Throttle / Brake ---
	var accel := Input.get_action_strength("accelerate")
	var brake_in := Input.get_action_strength("brake")

	# forward/back engine force
	if accel > 0.0:
		engine_force = accel * ENGINE_POWER
	elif brake_in > 0.0 and forward_speed() > 0.1:
		engine_force = 0.0
		brake = BRAKE_POWER * brake_in
	else:
		brake = 0.0
		engine_force = -Input.get_action_strength("brake") * REVERSE_POWER

	# light engine braking when off throttle
	if accel == 0.0 and brake_in == 0.0 and forward_speed() > 0.5:
		brake = max(brake, ENGINE_BRAKE)

	# --- Auto drift & stabilization ---
	apply_arcade_grip_and_drift(delta)

# ===== Helpers =====
func forward_speed() -> float:
	var v_local := global_transform.basis.inverse() * linear_velocity
	return max(0.0, -v_local.z)

func slip_angle_deg() -> float:
	var v_local := global_transform.basis.inverse() * linear_velocity
	return rad_to_deg(atan2(v_local.x, -v_local.z))

func apply_arcade_grip_and_drift(delta: float) -> void:
	var v_world := linear_velocity
	var v_local := global_transform.basis.inverse() * v_world

	var speed := v_local.length()
	var slip := slip_angle_deg()

	# drift condition
	_drifting = speed > DRIFT_MIN_SPEED and abs(slip) > DRIFT_ANGLE_DEG

	# Lateral “grip” = apply force opposite to sideways motion.
	var right := global_transform.basis.x
	var lateral_vel := right.dot(v_world)  # world-space lateral speed
	var desired_grip := (LATERAL_GRIP_DRIFT if _drifting else LATERAL_GRIP)

	# Apply a restoring force against lateral movement (oppose sideways velocity).
	apply_central_force(-right * lateral_vel * desired_grip)

	# Yaw stabilization (helps prevent spins, lower during drift)
	var up := global_transform.basis.y
	var yaw_control := (YAW_STABILIZE_DRIFT if _drifting else YAW_STABILIZE)
	apply_torque(-up * angular_velocity.y * yaw_control)
