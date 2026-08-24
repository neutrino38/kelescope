%global debug_package %{nil}
%global _build_id_links none
%global __requires_exclude_from ^/opt/kelescope/.*$
%global __provides_exclude_from ^/opt/kelescope/.*$

Name:           kelescope
Version:        0.1.0
Release:        1%{?dist}
Summary:        Interface d'administration web pour kelixip

License:        Proprietary
URL:            https://github.com/neutrino38/kelescope
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  elixir >= 1.17
BuildRequires:  erlang >= 26
BuildRequires:  systemd-rpm-macros
Requires:       openssl-libs
Requires:       ncurses-libs
Requires(pre):  shadow-utils
%{?systemd_requires}

%description
kelescope est l'interface d'administration web du serveur d'application
kelixip. Ce paquet installe une release Elixir/Phoenix autonome (runtime
Erlang inclus) dans /opt/kelescope, ainsi qu'un service systemd qui
l'expose en HTTPS sur le port 8443.

La compilation nécessite un accès réseau (hex.pm pour les dépendances,
GitHub pour les binaires autonomes esbuild/tailwind). Voir
docs/maintenance/paquet-rpm.md pour les détails et pour la mise en place
des certificats TLS.

%prep
%autosetup

%build
export HOME=%{_builddir}
export MIX_ENV=prod
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

install -Dm644 rpm/kelescope.service %{buildroot}%{_unitdir}/kelescope.service
install -Dm640 rpm/kelescope.env %{buildroot}%{_sysconfdir}/kelescope/kelescope.env

%pre
getent group kelixip >/dev/null || groupadd -r kelixip
getent passwd kelixip >/dev/null || \
    useradd -r -g kelixip -d /opt/kelescope -s /sbin/nologin \
    -c "Service kelixip/kelescope" kelixip
exit 0

%post
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

%preun
%systemd_preun kelescope.service

%postun
%systemd_postun_with_restart kelescope.service

%files
%defattr(-,root,root,-)
/opt/kelescope
%{_unitdir}/kelescope.service
%attr(0640,root,kelixip) %config(noreplace) %{_sysconfdir}/kelescope/kelescope.env

%changelog
* Mon Aug 24 2026 Emmanuel Buu <emmanuel.buu@ives.fr> - 0.1.0-1
- Paquet initial : release Elixir autonome, service systemd, HTTPS sur le port 8443.
