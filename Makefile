.PHONY: l10n l10n-server js-host js-armel js-armhf plugin-zip plugin-server-zip

l10n:
	msgfmt --check -o plugin/legado.koplugin/l10n/zh_CN/legado.mo plugin/legado.koplugin/l10n/zh_CN/legado.po

l10n-server:
	msgfmt --check -o plugin/legado-server.koplugin/l10n/zh_CN/legado-server.mo plugin/legado-server.koplugin/l10n/zh_CN/legado-server.po

js-host:
	OUT=plugin/legado.koplugin/lib/x86_64/liblegado_js.so tools/build-quickjs.sh host

js-armel:
	OUT=plugin/legado.koplugin/lib/armel/liblegado_js.so tools/build-quickjs.sh armel

js-armhf:
	OUT=plugin/legado.koplugin/lib/armhf/liblegado_js.so tools/build-quickjs.sh armhf

plugin-zip: l10n js-armel js-armhf
	mkdir -p dist
	cd plugin && zip -qr ../dist/legado.koplugin.zip legado.koplugin

plugin-server-zip: l10n-server
	mkdir -p dist
	cd plugin && zip -qr ../dist/legado-server.koplugin.zip legado-server.koplugin
