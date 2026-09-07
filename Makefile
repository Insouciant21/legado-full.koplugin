.PHONY: test js-host js-armel js-armhf plugin-zip

test:
	python3 -m unittest discover -v

js-host:
	OUT=plugin/legado.koplugin/lib/x86_64/liblegado_js.so tools/build-quickjs.sh host

js-armel:
	OUT=plugin/legado.koplugin/lib/armel/liblegado_js.so tools/build-quickjs.sh armel

js-armhf:
	OUT=plugin/legado.koplugin/lib/armhf/liblegado_js.so tools/build-quickjs.sh armhf

plugin-zip: js-armel js-armhf
	mkdir -p dist
	cd plugin && zip -qr ../dist/legado.koplugin.zip legado.koplugin
