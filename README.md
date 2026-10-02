ติดตั้ง jq ก่อน
apt update && apt install jq -y

แก้ไข DDNS_URLS  หากมีหลาย wan ให้ใส่ชื่อภายใต้ "" แล้วเว้นวรรค

ตั้ง cron
*/5 * * * * /root/update_pve_firewall.sh >/dev/null 2>&1
