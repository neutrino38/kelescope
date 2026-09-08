%global debug_package %{nil}
%global _build_id_links none
%global __requires_exclude_from ^/opt/kelescope/.*$
%global __provides_exclude_from ^/opt/kelescope/.*$

# Version d'ABI des applications chargees hors release. Figee : elle nomme les
# repertoires de /opt/kelescope/plugins, et ne suit pas la version produit.
%global abi 1.0.0

# Versions minimales entre paquets. A relever a la main quand une partie
# commence a employer une nouveaute du socle.
%global min_runtime 0.2.0
%global min_app 0.2.0

Name:           kelescope
Version:        0.2.0
Release:        1%{?dist}
Summary:        Interface d'administration web pour kelixip

License:        MIT
URL:            https://github.com/neutrino38/kelescope
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  erlang >= 26
BuildRequires:  systemd-rpm-macros

Requires:       kelescope-runtime >= %{min_runtime}
Requires:       kelescope-app >= %{min_app}

%description
kelescope est l'interface d'administration web du serveur d'application
kelixip. Ce paquet n'installe aucun fichier : il tire le socle
(kelescope-runtime) et l'application (kelescope-app).

Les deux se mettent a jour separement. Une correction de l'application ne
reexpedie pas le runtime Erlang.

%package runtime
Summary:        Socle d'execution de kelescope (runtime Erlang, service systemd)
Requires:       openssl-libs
Requires:       ncurses-libs
Requires(pre):  shadow-utils
%{?systemd_requires}

%description runtime
Release Elixir autonome installee dans /opt/kelescope : runtime Erlang,
dependances, script de demarrage et service systemd qui expose kelescope en
HTTPS sur le port 8443.

Ce paquet ne contient aucun code de kelescope. Il charge au demarrage les
applications presentes dans /opt/kelescope/plugins, fournies par
kelescope-app.

La compilation necessite un acces reseau (hex.pm pour les dependances,
GitHub pour les binaires autonomes esbuild/tailwind). Voir
docs/maintenance/paquet-rpm.md pour les details et pour la mise en place
des certificats TLS.

%package app
Summary:        Application kelescope (interface web)
Requires:         kelescope-runtime >= %{min_runtime}
Requires(posttrans): systemd
Requires(postun):    systemd

%description app
Code de l'interface web de kelescope, installe dans
/opt/kelescope/plugins. Ne contient ni runtime Erlang ni dependances : il
s'appuie sur celles de kelescope-runtime.

%prep
%autosetup

%build
elixir_version=$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9.]*\).*/\1/p')
if [ -z "$elixir_version" ]; then
    echo "elixir >= 1.17 requis pour construire ce paquet (introuvable dans PATH)" >&2
    exit 1
fi
if [ "$(printf '%s\n%s\n' "1.17" "$elixir_version" | sort -V | head -n1)" != "1.17" ]; then
    echo "elixir >= 1.17 requis pour construire ce paquet (detecte: $elixir_version)" >&2
    exit 1
fi

export HOME=%{_builddir}
export MIX_ENV=prod
export KELESCOPE_BUILD_VERSION=%{version}-%{release}
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix compile
mix assets.deploy
mix release --overwrite

%install
rm -rf %{buildroot}
install -d %{buildroot}/opt/kelescope
cp -a _build/prod/rel/kelescope/. %{buildroot}/opt/kelescope/

# priv est un lien symbolique dans _build : -L le deroule.
install -d %{buildroot}/opt/kelescope/plugins/kelescope-%{abi}
cp -aL _build/prod/lib/kelescope/ebin _build/prod/lib/kelescope/priv \
    %{buildroot}/opt/kelescope/plugins/kelescope-%{abi}/

install -Dm755 rpm/kelescope-reload-plugin %{buildroot}/opt/kelescope/bin/kelescope-reload-plugin

install -Dm644 rpm/kelescope.service %{buildroot}%{_unitdir}/kelescope.service
install -Dm640 rpm/kelescope.env %{buildroot}%{_sysconfdir}/kelescope/kelescope.env

%pre runtime
getent group kelixip >/dev/null || groupadd -r kelixip
getent passwd kelixip >/dev/null || \
    useradd -r -g kelixip -d /opt/kelescope -s /sbin/nologin \
    -c "Service kelixip/kelescope" kelixip
exit 0

%post runtime
%systemd_post kelescope.service

if [ "$1" -eq 1 ]; then
    env_file="%{_sysconfdir}/kelescope/kelescope.env"
    placeholder="kelixip@CHANGE-ME.example.org"
    current=$(grep -m1 '^KELIXIP_NODE=' "$env_file" | cut -d= -f2-)

    if [ -z "$current" ] || [ "$current" = "$placeholder" ]; then
        node=""
        if [ -t 0 ]; then
            printf 'Nom Erlang du noeud kelixip a superviser (ex. kelixip@host.example.org).\nLaisser vide pour le configurer plus tard : '
            read -r node || node=""
        fi

        tmp_file=$(mktemp)
        awk -v val="$node" '
            BEGIN { found = 0 }
            /^KELIXIP_NODE=/ { print "KELIXIP_NODE=" val; found = 1; next }
            { print }
            END { if (!found) print "KELIXIP_NODE=" val }
        ' "$env_file" > "$tmp_file" && cat "$tmp_file" > "$env_file"
        rm -f "$tmp_file"

        if [ -z "$node" ]; then
            echo "kelescope : KELIXIP_NODE n'est pas renseigne. A configurer dans $env_file, puis : systemctl restart kelescope"
        fi
    fi

    cert_file=$(grep -m1 '^KELESCOPE_SSL_CERTFILE=' "$env_file" | cut -d= -f2-)
    key_file=$(grep -m1 '^KELESCOPE_SSL_KEYFILE=' "$env_file" | cut -d= -f2-)

    if [ ! -r "$cert_file" ] || [ ! -r "$key_file" ]; then
        new_cert=""
        new_key=""
        if [ -t 0 ]; then
            printf 'Certificat TLS (PEM, chaine complete) [%s] : ' "$cert_file"
            read -r new_cert || new_cert=""
            printf 'Cle privee TLS (PEM) [%s] : ' "$key_file"
            read -r new_key || new_key=""
        fi

        [ -n "$new_cert" ] && cert_file="$new_cert"
        [ -n "$new_key" ] && key_file="$new_key"

        tmp_file=$(mktemp)
        awk -v cert="$cert_file" -v key="$key_file" '
            /^KELESCOPE_SSL_CERTFILE=/ { print "KELESCOPE_SSL_CERTFILE=" cert; next }
            /^KELESCOPE_SSL_KEYFILE=/  { print "KELESCOPE_SSL_KEYFILE=" key; next }
            { print }
        ' "$env_file" > "$tmp_file" && cat "$tmp_file" > "$env_file"
        rm -f "$tmp_file"

        if [ ! -r "$cert_file" ] || [ ! -r "$key_file" ]; then
            echo "kelescope : certificat ou cle TLS absent ou illisible ($cert_file, $key_file). A deposer avant de demarrer le service (voir docs/maintenance/paquet-rpm.md), chemins ajustables dans $env_file, puis : systemctl restart kelescope"
        fi
    fi
fi

%preun runtime
%systemd_preun kelescope.service

%postun runtime
%systemd_postun_with_restart kelescope.service

%posttrans app
/opt/kelescope/bin/kelescope-reload-plugin kelescope || :

%postun app
if [ "$1" -eq 0 ]; then
    systemctl try-restart kelescope >/dev/null 2>&1 || :
fi

%files

%files runtime
%defattr(-,root,root,-)
%dir /opt/kelescope
%dir /opt/kelescope/plugins
/opt/kelescope/bin
/opt/kelescope/erts-*
/opt/kelescope/lib
/opt/kelescope/releases
%{_unitdir}/kelescope.service
%attr(0640,root,kelixip) %config(noreplace) %{_sysconfdir}/kelescope/kelescope.env

%files app
%defattr(-,root,root,-)
/opt/kelescope/plugins/kelescope-%{abi}

%changelog
* Tue Sep 08 2026 Emmanuel Buu <emmanuel.buu@ives.fr> - 0.2.0-1
- Decoupage en kelescope-runtime et kelescope-app : une correction de
  l'interface web ne reexpedie plus le runtime Erlang.
- Ecran MCU (/mcu), vue des domaines et compteurs en direct.

* Tue Aug 25 2026 Emmanuel Buu <emmanuel.buu@ives.fr> - 0.1.1-1
- Panneau de statut kelixip (équivalent kelictl status) au-dessus du monitor, rafraîchi toutes les 20s.

* Mon Aug 24 2026 Emmanuel Buu <emmanuel.buu@ives.fr> - 0.1.0-1
- Paquet initial : release Elixir autonome, service systemd, HTTPS sur le port 8443.
