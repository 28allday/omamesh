# Run by omamesh inside Blender (blender -b --python-expr ... -- ARGS):
#   SRC DEST FORMAT RATIO TEXTURE QW QX QY QZ SCALE HEIGHT
# Turns the model the way the user set it upright (a glTF-space quaternion),
# scales it, optionally decimates it and shrinks its textures, then writes
# DEST as glb, obj or stl. STL is Z-up and sits on the build plate.
import json
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

args = sys.argv[sys.argv.index("--") + 1:]
src, dest, fmt = args[0], args[1], args[2]
ratio, texture = float(args[3]), int(args[4])
qw, qx, qy, qz = (float(v) for v in args[5:9])
scale = float(args[9])
target_height = float(args[10])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]

# glTF is Y-up and Blender Z-up: (x, y, z) -> (x, -z, y), and so is the axis.
turn = Quaternion((qw, qx, -qz, qy)).to_matrix().to_4x4()
transform = Matrix.Diagonal((scale, scale, scale, 1.0)) @ turn
# Bake each instance independently. Otherwise changing a parent's transform
# can move a child twice, and linked mesh data cannot receive different turns.
worlds = [(obj, obj.matrix_world.copy()) for obj in meshes]
bpy.ops.object.select_all(action="DESELECT")
for obj, world in worlds:
    obj.parent = None
    if obj.data.users > 1:
        obj.data = obj.data.copy()
    obj.matrix_world = transform @ world
    obj.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

if ratio < 1:
    for obj in meshes:
        bpy.context.view_layer.objects.active = obj
        modifier = obj.modifiers.new("decimate", "DECIMATE")
        modifier.ratio = ratio
        bpy.ops.object.modifier_apply(modifier=modifier.name)

if target_height > 0:
    # Transforms are now baked into the vertices, so these boxes give the
    # actual height, even for irregular geometry under rotated source nodes.
    bpy.context.view_layer.update()
    corners = [obj.matrix_world @ Vector(c) for obj in meshes for c in obj.bound_box]
    height = max(c.z for c in corners) - min(c.z for c in corners)
    if height <= 0:
        raise ValueError("The model has no height in this orientation")
    factor = target_height / height
    resize = Matrix.Diagonal((factor, factor, factor, 1.0))
    for obj in meshes:
        obj.matrix_world = resize @ obj.matrix_world

if texture > 0:
    for image in bpy.data.images:
        width, height = image.size
        if max(width, height) > texture:
            f = texture / max(width, height)
            image.scale(max(1, round(width * f)), max(1, round(height * f)))
            image.pack()  # so the exporters write the smaller pixels

if fmt == "stl":
    # Centre on the plate with the lowest point at z = 0.
    corners = [obj.matrix_world @ Vector(c) for obj in meshes for c in obj.bound_box]
    lo = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    hi = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    shift = Vector((-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))
    for obj in meshes:
        obj.matrix_world = Matrix.Translation(shift) @ obj.matrix_world
    bpy.ops.wm.stl_export(filepath=dest, ascii_format=False)
elif fmt == "obj":
    # OBJ keeps its textures beside it as files the .mtl points at.
    folder = os.path.dirname(dest)
    stem = os.path.splitext(os.path.basename(dest))[0]
    for n, image in enumerate(i for i in bpy.data.images if i.size[0] > 0):
        image.filepath_raw = os.path.join(folder, f"{stem}_texture{n}.png")
        image.file_format = "PNG"
        image.save()
    bpy.ops.wm.obj_export(filepath=dest, path_mode="RELATIVE", export_materials=True)
else:
    bpy.ops.export_scene.gltf(filepath=dest, export_format="GLB")

faces = sum(len(obj.data.polygons) for obj in meshes)
print("OMAMESH_EXPORT " + json.dumps({"file": dest, "faces": faces}), flush=True)
