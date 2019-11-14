yangdir = /usr/share/configd/yang

sbin_SCRIPTS = \
	scripts/system/twampd-config.pl \
	scripts/twamp-show-status.pl \
	scripts/show-twamp-sessions.py

bin_SCRIPTS = scripts/twping \
	      scripts/twamp-ping-rpc \
	      scripts/twping-json \
	      scripts/twping-output-to-json


cpiop = find  . ! -regex '\(.*~\|.*\.bak\|.*\.swp\|.*\#.*\#\)' -print0 | cpio -0pd

install-exec-hook:
	mkdir -p $(DESTDIR)$(yangdir)
	cd yang && $(cpiop) $(DESTDIR)$(yangdir)
