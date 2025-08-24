extends Camera3D

@export var target_distance: float = 5
@export var target_height: float = 2
@export var speed: float = 15

var follow_this: Node3D
var last_lookat: Vector3

func _ready():
	follow_this = get_parent() as Node3D
	last_lookat = follow_this.global_transform.origin
	current = true 

func _physics_process(delta: float) -> void:
	var car_xform: Transform3D = follow_this.global_transform
	var forward: Vector3 = -car_xform.basis.z.normalized()
	var up: Vector3 = Vector3.UP

	var car_pos: Vector3 = car_xform.origin
	var target_pos: Vector3 = car_pos - forward * target_distance + up * target_height

	var t: float = clamp(delta * speed, 0.0, 1.0)
	global_transform.origin = global_transform.origin.lerp(target_pos, t)

	var look_target: Vector3 = car_pos + forward * 2.0
	last_lookat = last_lookat.lerp(look_target, t)
	look_at(last_lookat, up)
