#!/usr/bin/env bash
# kit-cascade – мастер каскада: два сервера (входной и зарубежный) → цепочка.
# Запуск с вашего компьютера:  bash kit-cascade.sh   или   bash <(curl -fsSL .../kit-cascade.sh)
# Спросит IP, логин и пароль (или ключ) обоих серверов, поставит KIT, где его нет,
# и включит каскад: клиенты → входной сервер → зарубежный → интернет.
set -Eeuo pipefail

KIT_INSTALL_URL="https://raw.githubusercontent.com/alexisvaleev/3X-UI_KIT/v1.5.0/scripts/3x-ui.sh"

if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=''; Y=''; R=''; B=''; N=''; fi
say() { echo "$*"; }
ok() { echo "${G}✓${N} $*"; }
die() { echo "${R}Ошибка:${N} $*" >&2; exit 1; }

# Ввод всегда с терминала, даже когда скрипт запущен через curl|bash.
ask() { # приглашение [значение-по-умолчанию]
  local def=${2:-}
  if [[ -n $def ]]; then printf '%s [%s]: ' "$1" "$def" > /dev/tty; else printf '%s: ' "$1" > /dev/tty; fi
  IFS= read -r REPLY < /dev/tty || die "нет терминала для ввода"
  REPLY=${REPLY:-$def}
}
ask_secret() {
  printf '%s: ' "$1" > /dev/tty
  IFS= read -r -s REPLY < /dev/tty || die "нет терминала для ввода"
  echo > /dev/tty
}

command -v ssh >/dev/null || die "нужен ssh (клиент OpenSSH)."

echo "${B}Мастер каскада 3X-UI KIT${N}"
echo "Клиенты подключатся к входному серверу, а в интернет трафик выйдет с зарубежного."
echo "Пароль можно не вводить (просто Enter) – тогда используются ваши SSH-ключи."
echo

# Сервер: роль → массив параметров. ask_server входной ENTRY
ask_server() { # метка префикс
  local label=$1 pfx=$2 ip user pass
  ask "IP ${label} сервера"; ip=$REPLY
  [[ $ip =~ ^[A-Za-z0-9.-]+$ ]] || die "странный адрес: $ip"
  ask "Пользователь SSH на $ip" root; user=$REPLY
  ask_secret "Пароль SSH на $ip (Enter – ключи ssh-agent)"; pass=$REPLY
  printf -v "${pfx}_IP" '%s' "$ip"; printf -v "${pfx}_USER" '%s' "$user"; printf -v "${pfx}_PASS" '%s' "$pass"
}

ask_server "входного (к нему подключаются клиенты, например в РФ)" IN
echo
ask_server "зарубежного (выход в интернет)" OUT

# ssh_exec ПРЕФИКС команда... – выполняет команду на сервере, возвращая её вывод.
# Пароль в процессы не светим: sshpass берёт его из переменной окружения SSHPASS.
ssh_exec() { # IP USER PASS команда...
  local ip=$1 user=$2 pass=$3; shift 3
  if [[ -n $pass ]]; then
    command -v sshpass >/dev/null || die "для входа по паролю нужен sshpass: поставьте его (apt install sshpass / brew install hudochenkov/sshpass/sshpass) или используйте ключи."
    SSHPASS=$pass sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "$user@$ip" "$@"
  else
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "$user@$ip" "$@"
  fi
}

echo
say "Проверяю доступность серверов…"
for pfx in IN OUT; do
  ip=$(eval echo "\${${pfx}_IP}"); user=$(eval echo "\${${pfx}_USER}"); pass=$(eval echo "\${${pfx}_PASS}")
  ssh_exec "$ip" "$user" "$pass" true 2>/dev/null \
    || die "не подключился к $ip по SSH. Проверьте адрес, логин, пароль/ключ и что порт 22 открыт."
  ok "$ip: SSH работает"
done

# Установка KIT там, где его нет.
install_kit() { # IP USER PASS метка
  local ip=$1 user=$2 pass=$3 label=$4
  if ssh_exec "$ip" "$user" "$pass" 'command -v kit >/dev/null 2>&1' 2>/dev/null; then
    ok "$label ($ip): KIT уже установлен"
    return 0
  fi
  say "Ставлю KIT на $label сервер $ip – займёт несколько минут, не закрывайте окно."
  # Вывод установщика показываем как есть: там адрес панели и пароль, они пригодятся.
  ssh_exec "$ip" "$user" "$pass" "bash <(curl -fsSL $KIT_INSTALL_URL) -y" \
    || die "установка KIT на $ip не удалась – вывод выше. Разберитесь и запустите мастер снова: повторный запуск безопасен."
  ssh_exec "$ip" "$user" "$pass" 'command -v kit >/dev/null 2>&1' 2>/dev/null \
    || die "установка на $ip вроде прошла, но команда kit не появилась."
  ok "$label ($ip): KIT установлен"
}

echo
install_kit "$IN_IP" "$IN_USER" "$IN_PASS" "входной"
echo
install_kit "$OUT_IP" "$OUT_USER" "$OUT_PASS" "зарубежный"

# Зарубежный: export → ссылка для входного.
echo
say "Получаю каскадную ссылку с зарубежного сервера…"
exp=$(ssh_exec "$OUT_IP" "$OUT_USER" "$OUT_PASS" kit cascade export 2>&1) \
  || die "kit cascade export на зарубежном сервере не удался: $(tail -3 <<<"$exp")"
link=$(grep -o "vless://[^']*" <<<"$exp" | head -1)
[[ -n $link ]] || die "не нашёл ссылку в ответе зарубежного сервера: $(tail -3 <<<"$exp")"
ok "ссылка получена"

# Входной: включаем каскад (идемпотентно – повтор просто обновит outbound).
echo
say "Включаю каскад на входном сервере…"
out=$(ssh_exec "$IN_IP" "$IN_USER" "$IN_PASS" "kit cascade on '$link'" 2>&1) \
  || die "kit cascade on на входном не удался: $(tail -3 <<<"$out")"
grep -q . <<<"$out" && echo "$out" | sed 's/^/  /'

st=$(ssh_exec "$IN_IP" "$IN_USER" "$IN_PASS" kit cascade status 2>/dev/null || true)
echo
if grep -q 'включён' <<<"$st"; then
  ok "Каскад работает: клиенты → $IN_IP → $OUT_IP → интернет"
else
  die "каскад включился, но статус не подтвердился: $st"
fi

echo
echo "${B}Готово.${N} Что дальше:"
echo "  • Подписки и ссылки клиентов – как прежде с входного сервера $IN_IP, менять ничего не нужно."
echo "  • Посмотреть их: ssh $IN_USER@$IN_IP 'cat /root/3x-ui.txt' или 'kit links'."
echo "  • Выключить каскад: ssh $IN_USER@$IN_IP 'kit cascade off'."
echo "  • MTProto идёт к Telegram напрямую, минуя каскад – так задумано."
