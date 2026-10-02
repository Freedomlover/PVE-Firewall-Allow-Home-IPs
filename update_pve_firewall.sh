#!/bin/bash

# ==========================================
# ส่วนตั้งค่า
# ==========================================
# ระบุ URL DDNS ของบ้าน 
# - ถ้ามี 1 URL แต่ Resolve ได้ 4 IP (Round-robin) ใส่แค่อันเดียว
# - ถ้ามี 4 URL แยกกัน ให้ใส่ในวงเล็บโดยเว้นวรรค เช่น ("wan1.ddns.net" "wan2.ddns.net")
DDNS_URLS=("wan1.domain.com" "wan2.domain.com")

IPSET_NAME="home_wan_ips"
CACHE_FILE="/var/tmp/pve_home_wan_ips_cache.txt"
# ==========================================

# 1. ดึง IP จาก DDNS ทั้งหมด (กรองเฉพาะ IPv4 และตัด IP ซ้ำ)
NEW_IPS=$(for url in "${DDNS_URLS[@]}"; do
    getent ahosts "$url" | awk '{print $1}'
done | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)

# ถ้าค้นหา IP ไม่เจอ (อาจจะเน็ตหลุด) ให้จบการทำงานทันที
if [ -z "$NEW_IPS" ]; then
    exit 1
fi

# 2. เทียบ IP กับ Cache
if [ -f "$CACHE_FILE" ]; then
    OLD_IPS=$(cat "$CACHE_FILE")
    if [ "$NEW_IPS" == "$OLD_IPS" ]; then
        # IP ไม่เปลี่ยน ออกจากสคริปต์โดยไม่แตะ Firewall
        exit 0
    fi
fi


# --- เริ่มอัปเดต Firewall ผ่านคำสั่ง pvesh ---

# 3. ตรวจสอบว่ามี IPSet หรือยัง ถ้าไม่มีให้สร้าง
if ! pvesh get /cluster/firewall/ipset/${IPSET_NAME} >/dev/null 2>&1; then
    pvesh create /cluster/firewall/ipset -name ${IPSET_NAME} -comment "Dynamic IPs from Home WAN"
fi

# 4. ดึง IP เก่าใน IPSet ออกมา แล้วลบทิ้ง
EXISTING_IPS=$(pvesh get /cluster/firewall/ipset/${IPSET_NAME} --output-format json 2>/dev/null | jq -r '.[].cidr' 2>/dev/null)
while read -r old_ip; do
    [ -z "$old_ip" ] && continue
    pvesh delete "/cluster/firewall/ipset/${IPSET_NAME}/${old_ip}" >/dev/null 2>&1
done <<< "$EXISTING_IPS"

# 5. ใส่ IP ชุดใหม่เข้าไป
while read -r ip; do
    [ -z "$ip" ] && continue

    # ตัดตัวอักษรขึ้นบรรทัดใหม่หรือช่องว่างที่อาจจะหลงเหลืออยู่ออก
    clean_ip=$(echo "$ip" | tr -d '\r' | tr -d ' ')

   #echo "กำลังเพิ่ม IP: [$clean_ip]"

    pvesh create "/cluster/firewall/ipset/${IPSET_NAME}" -cidr "$clean_ip" >/dev/null 2>&1
done <<< "$NEW_IPS"


# 6. ตรวจสอบและสร้าง Rule (ถ้ายังไม่มี)
RULE_CHECK=$(pvesh get /cluster/firewall/rules --output-format json 2>/dev/null | jq -r '.[] | select(.dport? == "8006" and .source? == "+'${IPSET_NAME}'") | .pos' 2>/dev/null)

if [ -z "$RULE_CHECK" ]; then
    pvesh create /cluster/firewall/rules -action ACCEPT -type in -dport 8006 -proto tcp -source "+${IPSET_NAME}" -enable 1 -comment "Allow GUI from Home WAN IPs"
fi


# 7. บันทึก IP ล่าสุดลง Cache
echo "$NEW_IPS" > "$CACHE_FILE"
