cfgdir = $(datadir)/vyatta-cfg/templates
gentmpdir = generated-templates
share_perl5dir = /opt/vyatta/share/perl5/Vyatta/Qos
curverdir = $(sysconfdir)/config-migrate/current

sbin_SCRIPTS = scripts/vyatta-qos.pl
sbin_SCRIPTS += scripts/vyatta-qos-util.pl

share_perl5_DATA = lib/Vyatta/Qos/Util.pm
share_perl5_DATA += lib/Vyatta/Qos/FairQueue.pm
share_perl5_DATA += lib/Vyatta/Qos/TrafficShaper.pm
share_perl5_DATA += lib/Vyatta/Qos/ShaperClass.pm
share_perl5_DATA += lib/Vyatta/Qos/Match.pm
share_perl5_DATA += lib/Vyatta/Qos/RateLimiter.pm
share_perl5_DATA += lib/Vyatta/Qos/DropTail.pm
share_perl5_DATA += lib/Vyatta/Qos/LimiterClass.pm
share_perl5_DATA += lib/Vyatta/Qos/RoundRobin.pm
share_perl5_DATA += lib/Vyatta/Qos/NetworkEmulator.pm
share_perl5_DATA += lib/Vyatta/Qos/RandomDetect.pm
share_perl5_DATA += lib/Vyatta/Qos/TrafficLimiter.pm
share_perl5_DATA += lib/Vyatta/Qos/Priority.pm
share_perl5_DATA += lib/Vyatta/Qos/Shared.pm
share_perl5_DATA += lib/Vyatta/Qos/HFSCClass.pm
share_perl5_DATA += lib/Vyatta/Qos/HFSCShaper.pm
share_perl5_DATA += lib/Vyatta/Qos/FairQueueCodel.pm

etcdir           = /etc
etc_SCRIPTS      =

curver_DATA      = cfg-version/qos@1

cpiop = find  . ! -regex '\(.*~\|.*\.bak\|.*\.swp\|.*\#.*\#\)' -print0 | \
  cpio -0pd

all-local:
	rm -rf $(gentmpdir)
	./gen-interface-templates.pl $(gentmpdir)
	./gen-qos-match-templates.pl $(gentmpdir)

clean-local:
	rm -rf $(gentmpdir)

install-exec-hook:
	mkdir -p $(DESTDIR)$(cfgdir)
	mkdir -p $(DESTDIR)/etc/ppp/ip-up.d
	install -m 0755 scripts/ppp/qos $(DESTDIR)/etc/ppp/ip-up.d
	cd templates; $(cpiop) $(DESTDIR)$(cfgdir)
	cd $(gentmpdir); $(cpiop) $(DESTDIR)$(cfgdir)

