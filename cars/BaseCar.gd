extends VehicleBody3D

# ===================== DRIVING & HANDLING =====================
@export var STEER_SPEED: float = 1.4
@export var STEER_LIMIT: float = 0.6
@export var THROTTLE_FORCE: float = 80.0

# Speed-sensitive steering
@export var HIGH_SPEED_KMH: float = 200.0          # at/above this speed steering is reduced to the min factor
@export var HIGH_SPEED_STEER_MIN: float = 0.35     # 35% of base steer at HIGH_SPEED_KMH

# --- Drift tuning (Space key / ui_select) ---
@export var DRIFT_BRAKE: float = 0.25
@export var DRIFT_STEER_LIMIT: float = 0.45
@export var DRIFT_STEER_SPEED: float = 0.8
@export var DRIFT_REAR_SLIP: float = 0.3

# Stronger in lower gears, weaker in higher gears
const GEAR_TORQUE_MULT: Array[float] = [3.0, 2.1, 1.6, 1.25, 1.0]
@export var GEAR_TORQUE_SCALE: float = 1.0

@export var AUTO_UP_AT_TOP_RATIO: float = 0.92  # upshift when >= 92% of the gear's top speed

# --- Downshift overspeed smoothing ---
@export var DOWNSHIFT_SMOOTH_TIME: float = 1.0  # seconds
var downshift_smooth_timer: float = 0.0
var downshift_from_kmh: float = 0.0
var downshift_to_kmh: float = 0.0
var downshift_allowed_kmh: float = -1.0  # -1 = inactive

# --- Engine / gearbox ---
const GEARS_MAX_KMH: Array[float] = [51.0, 90.0, 132.0, 183.0, 212.0] # 1..5 tops
const REDLINE_RPM: float = 8000.0
const IDLE_RPM: float = 1000.0
const MIN_DRIVE_RPM: float = 1200.0
const SHIFT_RPM_DROP: float = 1100.0
var gear: int = 1

# --- Transmission mode & auto shift ---
var is_automatic: bool = false
const AUTO_UPSHIFT_RPM: float = 7300.0
const AUTO_DOWNSHIFT_RPM: float = 4300.0
const SHIFT_COOLDOWN: float = 0.25
var shift_cooldown: float = 0.0

# --- Sounds follow RPM ---
@export var MIN_PITCH: float = 1.0
@export var MAX_PITCH: float = 2.5
@export var PITCH_AT_RPM: float = 8000.0

# --- Top speed safety ---
@export var ABS_TOP_SPEED_KMH: float = 212.0

# --- Audio nodes ---
@onready var EngineSound: AudioStreamPlayer = $EngineSound
@onready var ScreechSound: AudioStreamPlayer = $ScreechSound

# >>> Bark sound (plays every 1s above 7800 RPM)
const BARK_RPM_THRESHOLD: float = 7800.0
const BARK_INTERVAL: float = 1.0
const BARK_STREAM: AudioStream = preload("res://sounds/bark.mp3")
var bark_timer: float = 0.0
var BarkSound: AudioStreamPlayer

# --- Tachometer (needle rotation: 0deg at 0rpm, +240deg at 8000rpm) ---
@export var TACH_SWEEP_DEG: float = 240.0
@export var TACH_MAX_RPM: float = REDLINE_RPM
@export var TACH_SMOOTH: float = 12.0      # higher = snappier
@export var TACH_OFFSET_DEG: float = 0.0
@export var tach_needle_path: NodePath = ^"Hud/Tachiometer/Needle"
@onready var TachNeedle: Node2D = get_node_or_null(tach_needle_path)

# --- State ---
var steer_target: float = 0.0
var was_drifting: bool = false
var engine_rpm: float = IDLE_RPM
var target_rpm: float = IDLE_RPM

# ===================== INPUT =====================
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = (event as InputEventKey).keycode
		if key == KEY_F:
			is_automatic = not is_automatic
			_update_hud_mode()
		elif key == KEY_T and not is_automatic and shift_cooldown <= 0.0:
			_shift_up()
		elif key == KEY_G and not is_automatic and shift_cooldown <= 0.0:
			_shift_down()

# ===================== LIFECYCLE =====================
func _ready() -> void:
	if EngineSound and not EngineSound.playing:
		EngineSound.play()
	if TachNeedle == null:
		push_warning("Tach needle path not found: " + str(tach_needle_path))
	_update_hud_mode()
	_update_hud_gear()

	# Setup BarkSound (auto-creates the node if you didn't add one in the scene)
	if has_node("BarkSound"):
		BarkSound = $BarkSound
	else:
		BarkSound = AudioStreamPlayer.new()
		BarkSound.name = "BarkSound"
		add_child(BarkSound)
	BarkSound.stream = BARK_STREAM

# ===================== TICK =====================
func _physics_process(delta: float) -> void:
	shift_cooldown = max(0.0, shift_cooldown - delta)

	# ---------------- Speed & HUD ----------------
	var speed_mps: float = linear_velocity.length()
	var speed_kmh: float = speed_mps * 3.6
	if has_node("Hud/speed"):
		$Hud/speed.text = str(round(speed_kmh)) + "  KM/H"

	# ---- Downshift smoothing update ----
	if downshift_smooth_timer > 0.0:
		downshift_smooth_timer = max(0.0, downshift_smooth_timer - delta)
		var tfrac: float = 1.0 - (downshift_smooth_timer / DOWNSHIFT_SMOOTH_TIME)
		downshift_allowed_kmh = lerp(downshift_from_kmh, downshift_to_kmh, tfrac)
	else:
		downshift_allowed_kmh = -1.0

	# ---------------- Steering (speed-sensitive) ----------------
	steer_target = Input.get_action_strength("ui_left") - Input.get_action_strength("ui_right")
	var drifting: bool = Input.is_action_pressed("ui_select")

	var base_limit: float = (DRIFT_STEER_LIMIT if drifting else STEER_LIMIT)
	var base_speed: float = (DRIFT_STEER_SPEED if drifting else STEER_SPEED)

	var t: float = clamp(speed_kmh / HIGH_SPEED_KMH, 0.0, 1.0)
	var speed_factor: float = lerp(1.0, HIGH_SPEED_STEER_MIN, t)
	var steer_limit: float = base_limit * speed_factor

	steering = move_toward(steering, steer_target * steer_limit, base_speed * delta)

	# ---------------- Throttle / Reverse ----------------
	var fwd_mps: float = transform.basis.x.x
	var accel_input: bool = Input.is_action_pressed("ui_down")
	var reverse_input: bool = Input.is_action_pressed("ui_up")

	traction(speed_mps)

	# Per-gear cap (and absolute)
	var gear_top_kmh: float = GEARS_MAX_KMH[gear - 1]
	var effective_top_kmh: float = min(gear_top_kmh, ABS_TOP_SPEED_KMH)

	# ---------------- Engine / RPM model ----------------
	var speed_ratio: float = 0.0
	if gear_top_kmh > 0.0:
		speed_ratio = clamp(speed_kmh / gear_top_kmh, 0.0, 1.0)
	target_rpm = max(IDLE_RPM, lerp(MIN_DRIVE_RPM, REDLINE_RPM, speed_ratio))

	if speed_kmh < 1.0 and not accel_input and not reverse_input:
		target_rpm = IDLE_RPM

	var rpm_lerp_t: float = clamp(10.0 * delta, 0.0, 1.0)
	engine_rpm = lerp(engine_rpm, target_rpm, rpm_lerp_t)

	# --- Bark on high RPM (every 1s above 7800 RPM) ---
	if engine_rpm > BARK_RPM_THRESHOLD:
		bark_timer += delta
		if bark_timer >= BARK_INTERVAL:
			bark_timer -= BARK_INTERVAL
			if BarkSound:
				BarkSound.play()
	else:
		bark_timer = 0.0

	# ---------------- Auto shifting (shifts even under throttle) ----------------
	if is_automatic and shift_cooldown <= 0.0:
		var current_top_kmh: float = GEARS_MAX_KMH[gear - 1]
		var near_gear_top: bool = speed_kmh >= (current_top_kmh * AUTO_UP_AT_TOP_RATIO)
		var on_throttle: bool = accel_input and not reverse_input

		if (engine_rpm >= AUTO_UPSHIFT_RPM or near_gear_top) and gear < GEARS_MAX_KMH.size():
			_shift_up()
		elif (engine_rpm <= AUTO_DOWNSHIFT_RPM) and gear > 1 and not on_throttle:
			_shift_down()

	# ---------------- Engine sound pitch from RPM ----------------
	if EngineSound:
		var pitch: float = lerp(MIN_PITCH, MAX_PITCH, clamp(engine_rpm / PITCH_AT_RPM, 0.0, 1.0))
		EngineSound.pitch_scale = pitch

	# ---------------- Apply forces ----------------
	var torque_scale: float = _torque_curve(engine_rpm)
	var gear_mul: float = GEAR_TORQUE_MULT[gear - 1] * GEAR_TORQUE_SCALE
	var headroom: float = clamp(1.0 - speed_ratio, 0.0, 1.0)
	var aero_taper: float = clamp(1.0 - (speed_kmh / 300.0), 0.5, 1.0)

	if accel_input:
		var drive_force: float = THROTTLE_FORCE * torque_scale * gear_mul * headroom * aero_taper
		engine_force = drive_force
		brake = 0.0
	elif reverse_input:
		if fwd_mps >= -1.0:
			engine_force = -THROTTLE_FORCE * 0.9 * 1.6
			brake = 0.0
		else:
			engine_force = 0.0
			brake = 1.0
	else:
		engine_force = 0.0
		brake = 0.0

	# ---------------- Drift behavior ----------------
	if drifting:
		brake = max(brake, DRIFT_BRAKE)
		if has_node("wheal2"):
			$wheal2.wheel_friction_slip = DRIFT_REAR_SLIP
		if has_node("wheal3"):
			$wheal3.wheel_friction_slip = DRIFT_REAR_SLIP
		if not was_drifting and ScreechSound:
			ScreechSound.pitch_scale = randf_range(0.9, 1.1)
			ScreechSound.play()
	else:
		if has_node("wheal2"):
			$wheal2.wheel_friction_slip = 3.0
		if has_node("wheal3"):
			$wheal3.wheel_friction_slip = 3.0

	was_drifting = drifting

	# ---------------- Tachometer Needle ----------------
	if is_instance_valid(TachNeedle):
		var target_deg: float = _rpm_to_deg(engine_rpm)
		var current_deg: float = TachNeedle.rotation_degrees
		var lerp_t2: float = clamp(TACH_SMOOTH * delta, 0.0, 1.0)
		TachNeedle.rotation_degrees = lerp(current_deg, target_deg, lerp_t2)

	# ---------------- HUD ----------------
	if has_node("Hud/rpm"):
		$Hud/rpm.text = str(int(engine_rpm)) + "  RPM"
	_update_hud_gear()
	_update_hud_mode()

	# downhill protection (skip while smoothing a downshift)
	if downshift_allowed_kmh < 0.0 and speed_kmh > effective_top_kmh + 0.5:
		brake = max(brake, 0.1)

# ===================== PHYSICS CAP =====================
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var v: Vector3 = state.linear_velocity
	var s: float = v.length()
	var current_gear_top: float = GEARS_MAX_KMH[gear - 1]

	var cap_kmh: float
	if downshift_allowed_kmh >= 0.0:
		cap_kmh = min(ABS_TOP_SPEED_KMH, downshift_allowed_kmh)
	else:
		cap_kmh = min(ABS_TOP_SPEED_KMH, current_gear_top)

	var cap_mps: float = cap_kmh / 3.6
	if s > cap_mps:
		state.linear_velocity = v * (cap_mps / s)

# ===================== HELPERS =====================
func traction(speed_mps: float) -> void:
	apply_central_force(Vector3.DOWN * speed_mps)

func _shift_up() -> void:
	if gear < GEARS_MAX_KMH.size():
		gear += 1
		engine_rpm = clamp(engine_rpm - SHIFT_RPM_DROP, IDLE_RPM, REDLINE_RPM)
		shift_cooldown = SHIFT_COOLDOWN
		_update_hud_gear()

func _shift_down() -> void:
	if gear > 1:
		gear -= 1
		var new_top: float = GEARS_MAX_KMH[gear - 1]
		var speed_kmh: float = linear_velocity.length() * 3.6
		var new_ratio: float = clamp(speed_kmh / new_top, 0.0, 1.0)
		var new_target: float = max(IDLE_RPM, lerp(MIN_DRIVE_RPM, REDLINE_RPM, new_ratio))
		engine_rpm = clamp(max(engine_rpm, new_target * 0.9), IDLE_RPM, REDLINE_RPM)
		shift_cooldown = SHIFT_COOLDOWN
		_update_hud_gear()

		if speed_kmh > new_top + 0.1:
			downshift_smooth_timer = DOWNSHIFT_SMOOTH_TIME
			downshift_from_kmh = speed_kmh
			downshift_to_kmh = new_top
			downshift_allowed_kmh = downshift_from_kmh

func _torque_curve(rpm: float) -> float:
	var x: float = clamp(rpm / REDLINE_RPM, 0.0, 1.0)
	var peak: float = 0.7
	var width: float = 0.55
	var val: float = 1.0 - pow(abs(x - peak) / width, 2.0)
	return clamp(val, 0.2, 1.0)

func _rpm_to_deg(rpm: float) -> float:
	var r: float = clamp(rpm, 0.0, TACH_MAX_RPM)
	return (r / TACH_MAX_RPM) * TACH_SWEEP_DEG + TACH_OFFSET_DEG

func _update_hud_gear() -> void:
	if has_node("Hud/gear"):
		$Hud/gear.text = str(gear)

func _update_hud_mode() -> void:
	if has_node("Hud/transmission"):
		$Hud/transmission.text = ("AUTOMATIC" if is_automatic else "MANUAL")
