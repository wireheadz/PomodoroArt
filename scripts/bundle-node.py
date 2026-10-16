"""Bundle non-system Node dylibs and rewrite their paths for a movable .app."""
import pathlib
import shutil
import subprocess
import sys

node = pathlib.Path(sys.argv[1]).resolve()
lib_dir = node.parent / "lib"
lib_dir.mkdir(exist_ok=True)
seen = {}

def run(*args):
    return subprocess.check_output(args, text=True)

def bundle(binary, original):
    lines = run("otool", "-L", str(binary)).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(" (", 1)[0]
        if dependency == original or dependency.startswith(("/usr/lib/", "/System/")):
            continue
        if dependency.startswith("@loader_path/"):
            source = pathlib.Path(original).resolve().parent / dependency.removeprefix("@loader_path/")
        else:
            source = pathlib.Path(dependency)
        if source.resolve() == pathlib.Path(original).resolve():
            continue
        if not source.is_absolute():
            raise RuntimeError(f"Unsupported runtime dependency: {dependency}")
        target = lib_dir / source.name
        resolved = str(source.resolve())
        if target.name in seen and seen[target.name] != resolved:
            raise RuntimeError(f"Conflicting library names: {target.name}")
        if target.name not in seen:
            seen[target.name] = resolved
            shutil.copyfile(source, target)
            target.chmod(0o755)
            subprocess.check_call(["install_name_tool", "-id", f"@loader_path/{target.name}", str(target)])
            bundle(target, str(source))
        relative = f"@loader_path/lib/{target.name}" if binary == node else f"@loader_path/{target.name}"
        subprocess.check_call(["install_name_tool", "-change", dependency, relative, str(binary)])

bundle(node, sys.argv[2])
