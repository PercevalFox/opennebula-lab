#!/usr/bin/env bash

VARS_FILE="${VARS_FILE:-./vars-opennebula.env}"
if [[ ! -f "$VARS_FILE" ]]; then echo "Vars file non trouvé: $VARS_FILE"; exit 1; fi
# shellcheck disable=SC1090
source "$VARS_FILE"

set -u

ROLE="${ROLE:-auto}"

pass=0; fail=0; warn=0
ok(){ echo -e "[OK]  $*"; pass=$((pass+1)); }
ko(){ echo -e "[ERR] $*"; fail=$((fail+1)); }
ww(){ echo -e "[WARN] $*"; warn=$((warn+1)); }

section(){ echo -e "\n=== $* ==="; }

# Déduction du rôle si auto
HOST="$(hostname -s || hostname)"
if [[ "$ROLE" == "auto" ]]; then
  if [[ "$HOST" == "$FRONTEND_HOSTNAME" || "$(hostname -f 2>/dev/null || true)" == "$FRONTEND_HOSTNAME" ]]; then
    ROLE="frontend"
  elif [[ "$HOST" == "$NODE_HOSTNAME" || "$(hostname -f 2>/dev/null || true)" == "$NODE_HOSTNAME" ]]; then
    ROLE="node"
  else
    ww "Hostname $HOST ne correspond ni à $FRONTEND_HOSTNAME ni à $NODE_HOSTNAME. Tu peux forcer: ROLE=frontend|node ./preflight.sh"
    ROLE="unknown"
  fi
fi

section "Rôle détecté"
echo "RÔLE: ${ROLE}"
echo "HOST: ${HOST}"

# OS
section "OS / version"
if grep -q "${OS_CODENAME}" /etc/os-release; then
  ok "Distro correspond à ${OS_CODENAME}"
else
  ko "Distro != ${OS_CODENAME} (vérifie OS_CODENAME dans vars-opennebula.env)"
fi

# CPU / Virtualisation
section "CPU / Virtualisation"
if lscpu | egrep -q 'vmx|svm'; then
  ok "Extensions virt (vmx/svm) détectées"
else
  ko "Pas d’extensions virt CPU (vmx/svm). Activer VT-x/AMD-V/Nested Virt."
fi
if lsmod | egrep -q '^kvm(_intel|_amd)?\b'; then
  ok "Modules KVM chargés"
else
  ww "Modules KVM non chargés (normal si paquets non installés encore)"
fi

# 3) Réseau de base
section "Réseau de base"
if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
  ok "Sortie Internet (ICMP) OK"
else
  ww "Ping 8.8.8.8 KO."
fi
if getent hosts downloads.opennebula.io >/dev/null 2>&1; then
  ok "Réso DNS downloads.opennebula.io OK"
else
  ko "DNS KO pour downloads.opennebula.io"
fi
if command -v curl >/dev/null 2>&1 && curl -sSfI https://downloads.opennebula.io/ >/dev/null 2>&1; then
  ok "Accès HTTPS au repo OpenNebula OK"
else
  ko "Accès HTTPS au repo OpenNebula KO"
fi

# 4) Bridge / interfaces
section "Interfaces / Bridge"
IFACES="$(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
echo "Interfaces: ${IFACES}"
if ip -o link show "${BRIDGE_NAME}" >/dev/null 2>&1; then
  ok "Bridge ${BRIDGE_NAME} détecté"
else
  if [[ "${CONFIGURE_NETPLAN_BRIDGE}" == "true" ]]; then
    ko "Bridge ${BRIDGE_NAME} attendu (CONFIGURE_NETPLAN_BRIDGE=true) mais absent"
  else
    ww "Bridge ${BRIDGE_NAME} non présent (OK si tu utilises une autre iface)"
  fi
fi

# 5) Services libvirt
section "libvirt"
if systemctl is-active --quiet libvirtd; then
  ok "libvirtd actif"
else
  ww "libvirtd inactif (sera installé/activé par les scripts)"
fi

# 6) Disque (datastore)
section "Espace disque"
DS_DIR="${DATASTORE_DIR:-/var/lib/one/datastores}"
mkdir -p "$DS_DIR" >/dev/null 2>&1 || true
FREE_MB="$(df -Pm "$DS_DIR" | awk 'NR==2{print $4}')"
echo "Datastore dir: $DS_DIR — Libre: ${FREE_MB} MiB"
if [[ "${FREE_MB:-0}" -ge 10240 ]]; then
  ok "≥ 10 GiB libres pour datastore"
else
  ww "< 10 GiB libres, augmente l’espace si tu crées des images/VMs"
fi

# 7) Vérifs spécifiques Frontend/Node
if [[ "$ROLE" == "frontend" ]]; then
  section "Frontend → Node (SSH)"
  # Test reachability TCP/22
  if command -v nc >/dev/null 2>&1 && nc -z -w2 "${NODE_IP}" 22 >/dev/null 2>&1; then
    ok "Port 22 joignable sur node ${NODE_IP}"
  else
    ww "TCP/22 vers ${NODE_IP} non joignable (firewall?)"
  fi
  # Test clé oneadmin si déjà configurée
  if id -u oneadmin >/dev/null 2>&1; then
    if sudo -u oneadmin ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_TARGET_USER}@${NODE_IP}" true 2>/dev/null; then
      ok "SSH oneadmin → node sans mot de passe OK"
    else
      ww "SSH oneadmin → node pas encore configuré (sera fait par setup-frontend.sh)"
    fi
  else
    ww "Utilisateur oneadmin pas encore présent (ok avant install frontend)"
  fi
fi

if [[ "$ROLE" == "node" ]]; then
  section "Node KVM – groupes"
  if getent group kvm >/dev/null 2>&1 && getent group libvirt >/dev/null 2>&1; then
    ok "Groupes kvm/libvirt présents"
  else
    ww "Groupes kvm/libvirt absents (seront créés via paquets)"
  fi
fi

# 7bis) Domaine / DNS quand FRONTEND_DOMAIN défini
if [[ -n "${FRONTEND_DOMAIN:-}" && "${ROLE}" == "frontend" ]]; then
  section "DNS / Domaine (${FRONTEND_DOMAIN})"
  if getent hosts "${FRONTEND_DOMAIN}" >/dev/null 2>&1; then
    RESOLVED_IP="$(getent hosts "${FRONTEND_DOMAIN}" | awk '{print $1}' | head -n1)"
    echo "Résolution: ${FRONTEND_DOMAIN} -> ${RESOLVED_IP}"
    if [[ -n "${FRONTEND_IP:-}" && "${RESOLVED_IP}" == "${FRONTEND_IP}" ]]; then
      ok "Le FQDN pointe bien sur FRONTEND_IP (${FRONTEND_IP})"
    else
      ww "Le FQDN ne pointe pas sur FRONTEND_IP (${FRONTEND_IP}). Pense à corriger DNS ou /etc/hosts"
    fi
  else
    ww "Le FQDN ${FRONTEND_DOMAIN} ne résout pas (DNS manquant ?)"
  fi
fi

# 8) Résumé
section "Résumé"
echo "PASS: $pass  WARN: $warn  FAIL: $fail"
if [[ $fail -gt 0 ]]; then
  echo "→ Corrige les [ERR] avant d’installer."
  exit 2
else
  echo "→ Préflight OK (avec ${warn} avertissements)."
  exit 0
fi
