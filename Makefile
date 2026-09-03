.PHONY: help test project open lint clean

help:
	@echo "Alarmy — make targets"
	@echo ""
	@echo "  make test      Run the AlarmyCore test suite (no Xcode project needed)"
	@echo "  make project   Generate Alarmy.xcodeproj from project.yml"
	@echo "  make open      Generate the project and open it in Xcode"
	@echo "  make clean     Remove build artefacts and the generated project"

# The most valuable command in this repo. It verifies every alarm rule —
# scheduling, DST, the state machine, Mission Guard and the anti-cheat logic —
# without a device, a simulator, or even an Xcode project.
test:
	cd AlarmyCore && swift test

project:
	@command -v xcodegen >/dev/null 2>&1 || { echo "XcodeGen not found. Run: brew install xcodegen"; exit 1; }
	xcodegen generate

open: project
	open Alarmy.xcodeproj

clean:
	rm -rf Alarmy.xcodeproj AlarmyCore/.build build DerivedData
