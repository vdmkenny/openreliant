"""Tests joystick and gamepad support on Linux with virtual controllers.

Creates uinput devices that report the same USB IDs, names, axes and buttons as real controllers,
so that openreliant reads them through SDL's normal Linux device code and its gamepad database,
then checks what `openreliant joysticks` reports. Usage: controllers.py <openreliant binary>.
Needs write access to /dev/uinput and the python3-evdev package.
"""
import os
import subprocess
import sys
import time

from evdev import AbsInfo, UInput, ecodes as e

BINARY = sys.argv[1]


def axis(low, high, value=None):
    return AbsInfo(value=(low + high) // 2 if value is None else value, min=low, max=high, fuzz=0, flat=0, resolution=0)


HAT = [(e.ABS_HAT0X, axis(-1, 1, 0)), (e.ABS_HAT0Y, axis(-1, 1, 0))]
STICK_BUTTONS = [e.BTN_TRIGGER, e.BTN_THUMB, e.BTN_THUMB2, e.BTN_TOP, e.BTN_TOP2, e.BTN_PINKIE,
                 e.BTN_BASE, e.BTN_BASE2, e.BTN_BASE3, e.BTN_BASE4, e.BTN_BASE5, e.BTN_BASE6]

CONTROLLERS = {
    # The Xbox 360 controller as the xpad driver reports it. SDL's database maps it as a gamepad.
    "xbox360": dict(name="Microsoft X-Box 360 pad", vendor=0x045E, product=0x028E, version=0x0114,
                    axes=[(e.ABS_X, axis(-32768, 32767, 0)), (e.ABS_Y, axis(-32768, 32767, 0)), (e.ABS_Z, axis(0, 255, 0)),
                          (e.ABS_RX, axis(-32768, 32767, 0)), (e.ABS_RY, axis(-32768, 32767, 0)), (e.ABS_RZ, axis(0, 255, 0))] + HAT,
                    buttons=[e.BTN_A, e.BTN_B, e.BTN_X, e.BTN_Y, e.BTN_TL, e.BTN_TR, e.BTN_SELECT, e.BTN_START, e.BTN_MODE,
                             e.BTN_THUMBL, e.BTN_THUMBR]),
    # A DualShock 4 as the kernel's hid-sony driver reports it.
    "dualshock4": dict(name="Sony Interactive Entertainment Wireless Controller", vendor=0x054C, product=0x09CC, version=0x8111,
                       axes=[(e.ABS_X, axis(0, 255)), (e.ABS_Y, axis(0, 255)), (e.ABS_Z, axis(0, 255, 0)),
                             (e.ABS_RX, axis(0, 255)), (e.ABS_RY, axis(0, 255)), (e.ABS_RZ, axis(0, 255, 0))] + HAT,
                       buttons=[e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_TL, e.BTN_TR, e.BTN_TL2, e.BTN_TR2,
                                e.BTN_SELECT, e.BTN_START, e.BTN_MODE, e.BTN_THUMBL, e.BTN_THUMBR]),
    # Logitech Extreme 3D Pro: X, Y, twist (Rz) and a throttle slider.
    "extreme3d": dict(name="Logitech Logitech Extreme 3D", vendor=0x046D, product=0xC215, version=0x0110,
                      axes=[(e.ABS_X, axis(0, 1023)), (e.ABS_Y, axis(0, 1023)), (e.ABS_RZ, axis(0, 255)),
                            (e.ABS_THROTTLE, axis(0, 255, 255))] + HAT,
                      buttons=STICK_BUTTONS),
    # Saitek X52: X, Y, throttle (Z), two rotaries, twist (Rz) and a slider.
    "x52": dict(name="Saitek Saitek X52 Flight Control System", vendor=0x06A3, product=0x0255, version=0x0111,
                axes=[(e.ABS_X, axis(0, 2047)), (e.ABS_Y, axis(0, 2047)), (e.ABS_Z, axis(0, 255, 255)), (e.ABS_RX, axis(0, 255)),
                      (e.ABS_RY, axis(0, 255)), (e.ABS_RZ, axis(0, 1023)), (e.ABS_THROTTLE, axis(0, 255))] + HAT,
                buttons=STICK_BUTTONS + [e.BTN_TRIGGER_HAPPY1 + i for i in range(20)]),
    # An old two-axis, four-button stick on a gameport adapter.
    "gameport": dict(name="Gameport Adapter Stick", vendor=0x1209, product=0x0002, version=0x0100,
                     axes=[(e.ABS_X, axis(0, 255)), (e.ABS_Y, axis(0, 255))], buttons=STICK_BUTTONS[:4]),
    # A gamepad no database knows, reporting joystick buttons as many cheap gamepads do.
    "generic": dict(name="Generic USB Pad", vendor=0x1209, product=0x0001, version=0x0111,
                    axes=[(e.ABS_X, axis(0, 255)), (e.ABS_Y, axis(0, 255)), (e.ABS_Z, axis(0, 255)), (e.ABS_RZ, axis(0, 255))] + HAT,
                    buttons=STICK_BUTTONS),
}

failures = []


def create(key):
    c = CONTROLLERS[key]
    device = UInput({e.EV_KEY: c["buttons"], e.EV_ABS: c["axes"]}, name=c["name"], vendor=c["vendor"],
                    product=c["product"], version=c["version"], bustype=e.BUS_USB)
    time.sleep(1)
    return device


def run(*args):
    result = subprocess.run([BINARY, "joysticks", *args], capture_output=True, text=True, timeout=20)
    return result.stdout + result.stderr


def watch(device, steps, directory="."):
    """Runs `joysticks --watch`, sends each step's events, and returns the last state line, with
    the line of the joystick's axes after it where there is one."""
    process = subprocess.Popen([BINARY, "joysticks", directory, "--watch"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    time.sleep(1.5)
    for step in steps:
        for kind, code, value in step:
            device.write(kind, code, value)
        device.syn()
        time.sleep(0.5)
    process.terminate()
    output, _ = process.communicate(timeout=5)
    lines = output.splitlines()
    states = [index for index, line in enumerate(lines) if line.startswith("X ")]
    if not states:
        return output
    last = states[-1]
    axes = lines[last + 1] if last + 1 < len(lines) and lines[last + 1].startswith("  axes:") else ""
    return lines[last] + "\n" + axes


def check(name, text, expected):
    missing = [part for part in expected if part not in text]
    if missing:
        failures.append(name)
        print(f"FAIL {name}: missing {missing} in:\n{text}")
    else:
        print(f"ok   {name}")


devices = [create(key) for key in CONTROLLERS]
listing = run()
check("Xbox 360 controller is a gamepad", listing, ["Xbox 360 Controller\n   gamepad"])
check("DualShock 4 is a gamepad", listing, ["Sony Interactive Entertainment Wireless Controller\n   gamepad"])
check("Extreme 3D Pro layout, and it is used", listing,
      ["Logitech Extreme 3D (used by the game)",
       "X: axis 0, Y: axis 1, throttle: axis 3 (automatic), twist: axis 2 (automatic)",
       "To choose it: Joystick=Logitech Extreme 3D"])
check("X52 layout", listing, ["X52 Flight Control System\n   joystick, USB ID 06a3:0255, 7 axes, 32 buttons, 1 hat\n"
                              "   X: axis 0, Y: axis 1, throttle: axis 2 (automatic), twist: axis 5 (automatic)"])
check("gameport stick layout", listing, ["2 axes, 4 buttons, 0 hats\n   X: axis 0, Y: axis 1, throttle: none (automatic), twist: none (automatic)"])
for device in devices:
    device.close()
time.sleep(1)

pad = create("xbox360")
state = watch(pad, [
    [(e.EV_ABS, e.ABS_X, -32768)],      # left stick hard left: X
    [(e.EV_ABS, e.ABS_RZ, 255)],        # right trigger: button 27
    [(e.EV_ABS, e.ABS_RY, -32768)],     # right stick up: button 28
    [(e.EV_KEY, e.BTN_A, 1)],           # A: button 0
    [(e.EV_ABS, e.ABS_HAT0Y, 1)],       # D-pad down: hat 180 and button 12
    [(e.EV_ABS, e.ABS_RX, 32767)],      # right stick right: twist and button 31
])
check("Xbox 360 controller input", state, ["X -1000", "twist 1000", "hat 180", "buttons down: 0 12 27 28 31"])
pad.close()
time.sleep(1)

pad = create("dualshock4")
state = watch(pad, [
    [(e.EV_ABS, e.ABS_RX, 255)],        # right stick right
    [(e.EV_ABS, e.ABS_Z, 255)],         # L2: button 26
    [(e.EV_KEY, e.BTN_WEST, 1)],        # square: button 2
])
check("DualShock 4 input", state, ["twist 1000", "buttons down: 2 26 31"])
pad.close()
time.sleep(1)

stick = create("extreme3d")
state = watch(stick, [
    [(e.EV_ABS, e.ABS_X, 1023)],        # stick full right
    [(e.EV_ABS, e.ABS_THROTTLE, 0)],    # throttle forward: full throttle, 0 for the game
    [(e.EV_ABS, e.ABS_RZ, 255)],        # twist right
    [(e.EV_ABS, e.ABS_HAT0X, -1)],      # hat left
    [(e.EV_KEY, e.BTN_TRIGGER, 1)],     # trigger: button 0
])
check("Extreme 3D Pro input", state, ["X 1000", "throttle 0", "twist 1000", "hat 270", "buttons down: 0",
                                      "0: 100% (X)", "1: 0% (Y)", "2: 100% (twist)", "3: -100% (throttle)"])
stick.close()
time.sleep(1)

stick = create("x52")
state = watch(stick, [
    [(e.EV_ABS, e.ABS_Z, 128)],         # throttle halfway
    [(e.EV_ABS, e.ABS_RZ, 0)],          # twist left
    [(e.EV_KEY, e.BTN_TRIGGER_HAPPY1 + 8, 1)],
])
check("X52 input", state, ["throttle 500", "twist -1000", "buttons down: 20", "2: 0% (throttle)", "5: -100% (twist)"])
stick.close()
time.sleep(1)

pad = create("generic")
check("unknown gamepad is read as a joystick", run(), ["Generic USB Pad (used by the game)\n   joystick"])
os.makedirs("/tmp/game", exist_ok=True)
with open("/tmp/game/gamecontrollerdb.txt", "w") as mappings:
    mappings.write("03000000091200000100000011010000,Generic USB Pad,a:b2,b:b1,x:b3,y:b0,back:b8,start:b9,"
                   "leftshoulder:b4,rightshoulder:b5,lefttrigger:b6,righttrigger:b7,leftstick:b10,rightstick:b11,"
                   "leftx:a0,lefty:a1,rightx:a2,righty:a3,dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8,platform:Linux,\n")
check("gamecontrollerdb.txt makes it a gamepad", run("/tmp/game"), ["Read 1 gamepad mapping", "Generic USB Pad (used by the game)\n   gamepad"])
state = watch(pad, [[(e.EV_KEY, e.BTN_BASE, 1)], [(e.EV_ABS, e.ABS_RZ, 0)]], "/tmp/game")
check("mapped gamepad input", state, ["buttons down: 26 28"])
pad.close()

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
