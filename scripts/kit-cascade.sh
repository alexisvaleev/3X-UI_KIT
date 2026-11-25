#!/usr/bin/env bash
# kit-cascade – мастер каскада: два сервера (входной и зарубежный) → цепочка.
# Запуск с вашего компьютера:  bash kit-cascade.sh   или   bash <(curl -fsSL .../kit-cascade.sh)
# Спросит IP, логин и пароль (или ключ) обоих серверов, поставит KIT, где его нет,
# и включит каскад: клиенты → входной сервер → зарубежный → интернет.
set -Eeuo pipefail

KIT_INSTALL_URL="https://raw.githubusercontent.com/alexisvaleev/3X-UI_KIT/v1.5.1/scripts/3x-ui.sh"

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
  ask "Порт SSH на $ip" 22; port=$REPLY
  [[ $port =~ ^[0-9]+$ ]] || die "порт должен быть числом: $port"
  ask_secret "Пароль SSH на $ip (Enter – ключи ssh-agent)"; pass=$REPLY
  printf -v "${pfx}_IP" '%s' "$ip"; printf -v "${pfx}_USER" '%s' "$user"; printf -v "${pfx}_PORT" '%s' "$port"; printf -v "${pfx}_PASS" '%s' "$pass"
}

ask_server "входного (к нему подключаются клиенты, например в РФ)" IN
echo
ask_server "зарубежного (выход в интернет)" OUT

# ssh_exec ПРЕФИКС команда... – выполняет команду на сервере, возвращая её вывод.
# Пароль в процессы не светим: sshpass берёт его из переменной окружения SSHPASS.
ssh_exec() { # IP USER PORT PASS команда...
  local ip=$1 user=$2 port=$3 pass=$4; shift 4
  # SSH_EXEC_TIMEOUT=N — необязательный жёсткий лимит на операцию; 0 = без лимита.
  if [[ -n $pass ]]; then
    command -v sshpass >/dev/null || die "для входа по паролю нужен sshpass: поставьте его (apt install sshpass / brew install hudochenkov/sshpass/sshpass) или используйте ключи."
    # BatchMode с паролем несовместим: ssh не станет спрашивать пароль, и sshpass не сможет его подставить.
    SSHPASS=$pass sshpass -e timeout "${SSH_EXEC_TIMEOUT:-0}" ssh -n -p "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "$user@$ip" "$@"
  else
    timeout "${SSH_EXEC_TIMEOUT:-0}" ssh -n -p "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "$user@$ip" "$@"
  fi
}

echo
say "Проверяю доступность серверов…"
for pfx in IN OUT; do
  ip=$(eval echo "\${${pfx}_IP}"); user=$(eval echo "\${${pfx}_USER}"); port=$(eval echo "\${${pfx}_PORT}"); pass=$(eval echo "\${${pfx}_PASS}")
  err=$(SSH_EXEC_TIMEOUT=25 ssh_exec "$ip" "$user" "$port" "$pass" true 2>&1 >/dev/null) && err=''
  if [[ -z $err ]]; then
    ok "$ip: SSH работает"
  elif grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' <<<"$err"; then
    die "ключ сервера $ip сменился — ssh защищает от подмены и не пускает.
  Если сервер переустанавливали вы, выполните и запустите мастер снова:
    ssh-keygen -R $ip
  Если не вы — не убирайте ключ, сначала проверьте сервер в панели провайдера."
  elif [[ -z $(tr -d '[:space:]' <<<"$err") ]]; then
    die "не подключился к $ip по SSH — сервер не ответил за 25 секунд. Проверьте, что он включён и порт $port не блокируется."
  else
    die "не подключился к $ip по SSH. Причина: $(tail -2 <<<"$err" | tr '\n' ' ')"
  fi
done

# Установка KIT там, где его нет.
install_kit() { # IP USER PORT PASS метка
  local ip=$1 user=$2 port=$3 pass=$4 label=$5
  if ssh_exec "$ip" "$user" "$port" "$pass" 'command -v kit >/dev/null 2>&1' 2>/dev/null; then
    ok "$label ($ip): KIT уже установлен"
    return 0
  fi
  say "Ставлю KIT на $label сервер $ip – займёт несколько минут, не закрывайте окно."
  # Вывод установщика показываем как есть: там адрес панели и пароль, они пригодятся.
  ssh_exec "$ip" "$user" "$port" "$pass" "bash <(curl -fsSL $KIT_INSTALL_URL) -y" \
    || die "установка KIT на $ip не удалась – вывод выше. Разберитесь и запустите мастер снова: повторный запуск безопасен."
  ssh_exec "$ip" "$user" "$port" "$pass" 'command -v kit >/dev/null 2>&1' 2>/dev/null \
    || die "установка на $ip вроде прошла, но команда kit не появилась."
  ok "$label ($ip): KIT установлен"
}

echo
install_kit "$IN_IP" "$IN_USER" "$IN_PORT" "$IN_PASS" "входной"
echo
install_kit "$OUT_IP" "$OUT_USER" "$OUT_PORT" "$OUT_PASS" "зарубежный"

# Зарубежный: export → ссылка для входного.
echo
say "Получаю каскадную ссылку с зарубежного сервера…"
exp=$(ssh_exec "$OUT_IP" "$OUT_USER" "$OUT_PORT" "$OUT_PASS" kit cascade export 2>&1) \
  || die "kit cascade export на зарубежном сервере не удался: $(tail -3 <<<"$exp")"
link=$(grep -o "vless://[^']*" <<<"$exp" | head -1)
[[ -n $link ]] || die "не нашёл ссылку в ответе зарубежного сервера: $(tail -3 <<<"$exp")"
ok "ссылка получена"

# Входной: включаем каскад (идемпотентно – повтор просто обновит outbound).
echo
say "Включаю каскад на входном сервере…"
out=$(ssh_exec "$IN_IP" "$IN_USER" "$IN_PORT" "$IN_PASS" "kit cascade on '$link'" 2>&1) \
  || die "kit cascade on на входном не удался: $(tail -3 <<<"$out")"
grep -q . <<<"$out" && echo "$out" | sed 's/^/  /'

st=$(ssh_exec "$IN_IP" "$IN_USER" "$IN_PORT" "$IN_PASS" kit cascade status 2>/dev/null || true)
echo
if grep -q 'включён' <<<"$st"; then
  ok "Каскад работает: клиенты → $IN_IP → $OUT_IP → интернет"
else
  die "каскад включился, но статус не подтвердился: $st"
fi

echo
echo "${B}Готово.${N} Что дальше:"
echo "  • Подписки и ссылки клиентов – как прежде с входного сервера $IN_IP, менять ничего не нужно."
ssh_hint="ssh $IN_USER@$IN_IP"; [[ $IN_PORT != 22 ]] && ssh_hint="ssh -p $IN_PORT $IN_USER@$IN_IP"
echo "  • Посмотреть их: $ssh_hint 'cat /root/3x-ui.txt' или 'kit links'."
echo "  • Выключить каскад: $ssh_hint 'kit cascade off'."
echo "  • MTProto идёт к Telegram напрямую, минуя каскад – так задумано."
