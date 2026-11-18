from PySide6.QtCore import QObject, Signal, QTimer

BUTTONS = ["A", "B", "X", "Y", "L1", "R1", "L2", "R2", "L3", "R3", "Menu", "Options"]
STICK_STEPS = ["Left stick · haut", "Left stick · bas", "Left stick · gauche", "Left stick · droite",
               "Right stick · haut", "Right stick · bas", "Right stick · gauche", "Right stick · droite"]
DPAD_STEPS = ["D-pad · haut", "D-pad · bas", "D-pad · gauche", "D-pad · droite"]
CALIBRATION_STEPS = BUTTONS + DPAD_STEPS + STICK_STEPS

class ControllerMonitor(QObject):
    devices_changed = Signal(list)
    input_detected = Signal(int, str, float)
    error = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._timer = QTimer(self)
        self._timer.setInterval(35)
        self._timer.timeout.connect(self.poll)
        self._controllers = []
        self._previous = {}
        self._last_devices = None
        self.available = False
        self._load_framework()

    def _load_framework(self):
        try:
            import GameController
            self.GCController = GameController.GCController
            self.available = True
        except Exception as exc:
            self.error.emit("API GameController indisponible. Installe les dépendances macOS puis relance NXManager. " + str(exc))

    def start(self):
        if not self.available:
            return
        try:
            self.GCController.startWirelessControllerDiscoveryWithCompletionHandler_(lambda: None)
        except Exception:
            pass
        self._timer.start()
        self.poll()

    def stop(self):
        self._timer.stop()

    def devices(self):
        if not self.available:
            return []
        try:
            return list(self.GCController.controllers() or [])
        except Exception:
            return []

    @staticmethod
    def _name(controller):
        for attr in ("vendorName", "productCategory"):
            try:
                value = getattr(controller, attr)()
                if value:
                    return str(value)
            except Exception:
                pass
        return "Manette détectée"

    def poll(self):
        controllers = self.devices()
        devices = []
        for index, controller in enumerate(controllers):
            name = self._name(controller)
            identifier = f"{name}:{index}"
            devices.append({"id": identifier, "name": name, "index": index})
        if devices != self._last_devices:
            self._last_devices = devices
            self._controllers = controllers
            self.devices_changed.emit(devices)
        else:
            self._controllers = controllers

        for index, controller in enumerate(self._controllers):
            try:
                profile = controller.extendedGamepad()
                if profile is None:
                    profile = controller.microGamepad()
                if profile is None:
                    continue
                self._poll_profile(profile, index)
            except Exception:
                continue

    def _poll_profile(self, profile, index):
        button_map = {
            "A": "buttonA", "B": "buttonB", "X": "buttonX", "Y": "buttonY",
            "L1": "leftShoulder", "R1": "rightShoulder", "L2": "leftTrigger", "R2": "rightTrigger",
            "L3": "leftThumbstickButton", "R3": "rightThumbstickButton",
            "Menu": "buttonMenu", "Options": "buttonOptions",
        }
        for logical, attr in button_map.items():
            try:
                element = getattr(profile, attr)()
                if element is None:
                    continue
                pressed = bool(element.isPressed())
                key = (index, logical)
                was = self._previous.get(key, False)
                if pressed and not was:
                    self.input_detected.emit(index, logical, 1.0)
                self._previous[key] = pressed
            except Exception:
                continue
        try:
            dpad = profile.dpad()
            for direction, attr in (("haut", "up"), ("bas", "down"), ("gauche", "left"), ("droite", "right")):
                key = (index, f"D-pad:{direction}")
                pressed = bool(getattr(dpad, attr)().isPressed())
                was = self._previous.get(key, False)
                if pressed and not was:
                    self.input_detected.emit(index, f"D-pad · {direction}", 1.0)
                self._previous[key] = pressed
        except Exception:
            pass
        for stick_name, attr in (("Left stick", "leftThumbstick"), ("Right stick", "rightThumbstick")):
            try:
                stick = getattr(profile, attr)()
                x = float(stick.xAxis().value())
                y = float(stick.yAxis().value())
                for direction, active in (("haut", y > 0.65), ("bas", y < -0.65),
                                          ("gauche", x < -0.65), ("droite", x > 0.65)):
                    key = (index, f"{stick_name}:{direction}")
                    was = self._previous.get(key, False)
                    if active and not was:
                        self.input_detected.emit(index, f"{stick_name} · {direction}", max(abs(x), abs(y)))
                    self._previous[key] = active
            except Exception:
                continue

    def device_name(self, index=0):
        try:
            return self._name(self._controllers[index])
        except Exception:
            return "Manette"
