.PHONY: check test generate build website

check:
	python3 scripts/check_privacy.py
	python3 -m unittest discover -s scripts/tests

test: check
	swift test --package-path packages/PlacesCore

generate:
	xcodegen generate --spec apps/ios/project.yml

build:
	xcodebuild -project apps/ios/Places.xcodeproj -scheme Places -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

website:
	python3 -m http.server 4173 --bind 127.0.0.1 --directory apps/website
