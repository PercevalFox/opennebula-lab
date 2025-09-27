#!/usr/bin/env bash
VARS_FILE="${VARS_FILE:-./vars-opennebula.env}"
if [[ ! -f "$VARS_FILE" ]]; then echo "Vars file non trouvé: $VARS_FILE"; exit 1; fi
# shellcheck disable=SC1090
source "$VARS_FILE"

# Sécu bash
if [[ "${SET_STRICT_BASH}" == "true" ]]; then set -euo pipefail; fi

# Helpers
log(){ printf "\n[+] %s\n" "$*"; }
run(){ echo "+ $*"; eval "$*"; }

# Prep APT
if [[ "${NON_INTERACTIVE}" == "true" ]]; then export DEBIAN_FRONTEND=noninteractive; fi

log "Vérif OS"
if ! grep -q "${OS_CODENAME}" /etc/os-release; then
  echo "Ce script cible ${OS_CODENAME}. Vérifie ta distro."; exit 1
fi

log "Config hostname et TZ"
run "sudo hostnamectl set-hostname ${FRONTEND_HOSTNAME}"
run "sudo timedatectl set-timezone ${TIMEZONE}"

log "MAJ systeme"
run "sudo apt update"
run "sudo apt upgrade -y"
run "sudo apt autoremove -y"

log "Install prérequis KVM/libvirt/bridge"
run "sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils ssh ${EXTRA_FRONTEND_PACKAGES}"
run "sudo systemctl enable --now libvirtd"

if [[ "${CONFIGURE_NETPLAN_BRIDGE}" == "true" ]]; then
  log "Configurer Netplan bridge ${BRIDGE_NAME} (⚠️ peut cut la session ssh)"
  NETPLAN="/etc/netplan/01-${BRIDGE_NAME}.yaml"
  run "sudo bash -c 'cat > ${NETPLAN} <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${PHYS_IFACE}:
      dhcp4: no
  bridges:
    ${BRIDGE_NAME}:
      interfaces: [${PHYS_IFACE}]
      addresses: [${BRIDGE_CIDR}]
      gateway4: ${GATEWAY_IP}
      nameservers:
        addresses: [${DNS_SERVERS}]
EOF'"
  run "sudo netplan apply"
fi

log "Ajouter dépôt OpenNebula ${ONE_REPO_MAJOR} (${ONE_REPO_CHANNEL})"
APT_FILE="/etc/apt/sources.list.d/opennebula.list"
run "echo \"deb [trusted=yes] https://downloads.opennebula.io/repo/${ONE_REPO_MAJOR}/Ubuntu/${OS_CODENAME} ${ONE_REPO_CHANNEL} ${ONE_REPO_NAME}\" | sudo tee ${APT_FILE} >/dev/null"
run "sudo apt update"

log "Install Front (core + Sunstone + FireEdge)"
run "sudo apt install -y opennebula opennebula-sunstone opennebula-fireedge"

log "Active services OpenNebula"
run "sudo systemctl enable opennebula opennebula-sunstone opennebula-fireedge"
run "sudo systemctl start opennebula opennebula-sunstone opennebula-fireedge"

# AJOUT Domaine / Apache / HTTPS
if [[ -n "${FRONTEND_DOMAIN:-}" && "${ENABLE_APACHE_PROXY}" == "true" ]]; then
  log "Configurer Apache comme reverse-proxy pour Sunstone via ${FRONTEND_DOMAIN}"
  run "sudo apt install apache2 -y"
  run "sudo a2enmod proxy proxy_http headers rewrite ssl >/dev/null || true"

  # Option: /etc/hosts si pas de DNS
  if [[ "${ADD_HOSTS_ENTRIES}" == "true" ]]; then
    if ! grep -q \"${FRONTEND_DOMAIN}\" /etc/hosts; then
      run "echo \"${FRONTEND_IP} ${FRONTEND_DOMAIN}\" | sudo tee -a /etc/hosts >/dev/null"
    fi
  fi

  # vhost HTTP (port 80)
  VHOST_HTTP="/etc/apache2/sites-available/sunstone-http.conf"
  run "sudo bash -c 'cat > ${VHOST_HTTP} <<EOF
<VirtualHost *:80>
    ServerName ${FRONTEND_DOMAIN}
    <IfModule mod_headers.c>
      RequestHeader set X-Forwarded-Proto \"http\"
    </IfModule>
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:${SUNSTONE_PORT}/
    ProxyPassReverse / http://127.0.0.1:${SUNSTONE_PORT}/

    ErrorLog \${APACHE_LOG_DIR}/sunstone_error.log
    CustomLog \${APACHE_LOG_DIR}/sunstone_access.log combined
</VirtualHost>
EOF'"

  run "sudo a2ensite sunstone-http >/dev/null"

  # HTTPS avec cert existant (si LE activé plus bas ça réécrira)
  if [[ -d /etc/letsencrypt/live/${FRONTEND_DOMAIN} ]]; then
    VHOST_HTTPS="/etc/apache2/sites-available/sunstone-https.conf"
    run "sudo bash -c 'cat > ${VHOST_HTTPS} <<EOF
<VirtualHost *:443>
    ServerName ${FRONTEND_DOMAIN}
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${FRONTEND_DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${FRONTEND_DOMAIN}/privkey.pem

    <IfModule mod_headers.c>
      RequestHeader set X-Forwarded-Proto \"https\"
    </IfModule>
    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:${SUNSTONE_PORT}/
    ProxyPassReverse / http://127.0.0.1:${SUNSTONE_PORT}/

    ErrorLog \${APACHE_LOG_DIR}/sunstone_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/sunstone_ssl_access.log combined
</VirtualHost>
EOF'"
    run "sudo a2enmod ssl >/dev/null"
    run "sudo a2ensite sunstone-https >/dev/null"

    if [[ \"${FORCE_HTTP_REDIRECT_TO_HTTPS}\" == \"true\" ]]; then
      # Petite redirection 80>443
      REDIR_FILE="/etc/apache2/conf-available/sunstone-redirect.conf"
      run "sudo bash -c 'cat > ${REDIR_FILE} <<EOF
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteCond %{HTTPS} !=on
  RewriteRule ^/(.*)$ https://%{HTTP_HOST}/\$1 [R=301,L]
</IfModule>
EOF'"
      run "sudo a2enconf sunstone-redirect >/dev/null"
    fi
  fi

  run "sudo systemctl reload apache2 || sudo systemctl restart apache2"
fi

# Let’s Encrypt
if [[ -n "${FRONTEND_DOMAIN:-}" && "${ENABLE_LETSENCRYPT}" == "true" ]]; then
  log "Obtenir/renouveler certificat Let’s Encrypt pour ${FRONTEND_DOMAIN}"
  run "sudo apt install -y certbot python3-certbot-apache"
  STAGING_FLAG=""
  if [[ \"${LETSENCRYPT_STAGING}\" == \"true\" ]]; then STAGING_FLAG=\"--staging\"; fi
  if [[ -z \"${LETSENCRYPT_EMAIL}\" ]]; then
    echo \"LETSENCRYPT_EMAIL est requis\"; exit 1
  fi
  # Non-interactif
  run "sudo certbot --apache -d ${FRONTEND_DOMAIN} -m ${LETSENCRYPT_EMAIL} --agree-tos --redirect ${STAGING_FLAG} --non-interactive"

  # (Ré)activer vhost HTTPS si besoin
  VHOST_HTTPS="/etc/apache2/sites-available/sunstone-https.conf"
  if [[ ! -f \"${VHOST_HTTPS}\" ]]; then
    run "sudo a2enmod ssl >/dev/null || true"
    run "sudo a2ensite sunstone-https >/dev/null || true"
  fi
  if [[ \"${FORCE_HTTP_REDIRECT_TO_HTTPS}\" == \"true\" ]]; then
    REDIR_FILE="/etc/apache2/conf-available/sunstone-redirect.conf"
    if [[ ! -f \"${REDIR_FILE}\" ]]; then
      run "sudo bash -c 'cat > ${REDIR_FILE} <<EOF
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteCond %{HTTPS} !=on
  RewriteRule ^/(.*)$ https://%{HTTP_HOST}/\$1 [R=301,L]
</IfModule>
EOF'"
      run "sudo a2enconf sunstone-redirect >/dev/null"
    fi
  fi
  run "sudo systemctl reload apache2 || sudo systemctl restart apache2"
fi

log "Infos Sunstone"
echo "URL:  http://${FRONTEND_IP}:${SUNSTONE_PORT}/"
echo "User: oneadmin"
echo "Pass: (voir) sudo cat /var/lib/one/.one/one_auth"

log "Préparer SSH pour l’utilisateur oneadmin (clé ${SSH_KEY_TYPE})"
if [[ "${CREATE_SSH_KEY_IF_MISSING}" == "true" ]]; then
  run "sudo -u oneadmin bash -lc 'test -f ~/.ssh/id_${SSH_KEY_TYPE} || ssh-keygen -t ${SSH_KEY_TYPE} -N \"\" -f ~/.ssh/id_${SSH_KEY_TYPE}'"
fi

log "Bootstrap SSH vers le node (${SSH_TARGET_USER}@${NODE_IP})"
if [[ -n "${NODE_SSH_PASSWORD}" ]]; then
  run "sudo apt install -y sshpass"
  run "sudo -u oneadmin bash -lc 'sshpass -p \"${NODE_SSH_PASSWORD}\" ssh-copy-id -o StrictHostKeyChecking=no ${SSH_TARGET_USER}@${NODE_IP}'"
else
  echo ">>> Si demandé, entre le mot de passe de ${SSH_TARGET_USER}@${NODE_IP} pour copier la clé."
  run "sudo -u oneadmin bash -lc 'ssh-copy-id -o StrictHostKeyChecking=no ${SSH_TARGET_USER}@${NODE_IP}'"
fi

log "Test SSH sans pass"
run "sudo -u oneadmin bash -lc 'ssh -o BatchMode=yes ${SSH_TARGET_USER}@${NODE_IP} true'"

log "Créer l’hôte OpenNebula pour node KVM"
run "sudo -u oneadmin onehost create ${NODE_HOSTNAME} -i kvm -v kvm -n dummy"

if [[ "${ADD_FRONTEND_AS_COMPUTE}" == "true" ]]; then
  log "Ajoute le Frontend comme hote compute (hybride)"
  run "sudo -u oneadmin onehost create ${FRONTEND_HOSTNAME} -i kvm -v kvm -n dummy"
fi

log "Vérifie l’état des hôtes"
run "sudo -u oneadmin onehost list || true"

log "It's DONE =D — Et voilà Eze =D connecte-toi à Sunstone: http://${FRONTEND_IP}:${SUNSTONE_PORT}/"
