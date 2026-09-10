.PHONY: test l10n js-host js-armel js-armhf plugin-zip

test:
	python3 -m unittest discover -v

l10n:
	msgfmt --check -o plugin/legado.koplugin/l10n/zh_CN/legado.mo plugin/legado.koplugin/l10n/zh_CN/legado.po

js-host:
	OUT=plugin/legado.koplugin/lib/x86_64/liblegado_js.so tools/build-quickjs.sh host

js-armel:
	OUT=plugin/legado.koplugin/lib/armel/liblegado_js.so tools/build-quickjs.sh armel

js-armhf:
	OUT=plugin/legado.koplugin/lib/armhf/liblegado_js.so tools/build-quickjs.sh armhf

plugin-zip: l10n js-armel js-armhf
	mkdir -p dist
	cd plugin && zip -qr ../dist/legado.koplugin.zip legado.koplugin
