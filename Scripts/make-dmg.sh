#!/bin/bash
# Đóng gói ProxyManClone thành .dmg để mang sang máy Mac khác.
#
# QUAN TRỌNG — app chỉ được ad-hoc sign, KHÔNG notarize. Trên máy khác,
# Gatekeeper sẽ chặn lần mở đầu tiên. Xem README trong dmg để biết cách mở.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="ProxyManClone.app"
VOL="ProxyManClone"
DMG="ProxyManClone.dmg"
STAGE=".dmg-stage"

./Scripts/make-app.sh release

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/ĐỌC TRƯỚC KHI CÀI.txt" <<'README'
ProxyManClone — proxy bắt và soi HTTP/HTTPS
===========================================

CÀI
1. Kéo ProxyManClone.app vào thư mục Applications bên cạnh.

MỞ LẦN ĐẦU — Gatekeeper sẽ chặn
App này chỉ được ad-hoc sign, chưa notarize với Apple, nên lần mở đầu
macOS sẽ báo "không mở được vì không xác minh được nhà phát triển".

Cách mở:
  1. Mở app một lần (nó sẽ bị chặn).
  2. Vào System Settings -> Privacy & Security.
  3. Kéo xuống, bấm "Open Anyway" ở dòng nhắc về ProxyManClone.

Hoặc bằng terminal:
  xattr -dr com.apple.quarantine /Applications/ProxyManClone.app

DÙNG
1. Bấm "Cài Root CA" -> macOS hỏi mật khẩu ĐĂNG NHẬP (không phải admin).
   CA được tin cho RIÊNG tài khoản đang dùng, không phải cho cả máy —
   đủ cho Safari, Chrome, curl của tài khoản đó, và không cần quyền root.
   CA được sinh RIÊNG trên từng máy. Máy mới sẽ có CA mới của chính nó;
   khoá riêng không bao giờ rời khỏi máy đã sinh ra nó.

   Nếu cần tin cho CẢ MÁY (mọi tài khoản), chạy tay trong Terminal:
     sudo security add-trusted-cert -d -r trustRoot \
       -k /Library/Keychains/System.keychain \
       ~/Library/Application\ Support/ProxyManClone/ca/ca.pem
   Việc này KHÔNG làm được từ trong app: bước đánh dấu tin cậy cần một
   hộp thoại trong phiên GUI, mà tiến trình root không có.
2. Bấm "Chạy" -> proxy nghe ở 127.0.0.1:9090.
3. Cho traffic đi qua:
     curl -x 127.0.0.1:9090 https://example.com/
   hoặc đặt system proxy:
     networksetup -setwebproxy       Wi-Fi 127.0.0.1 9090
     networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 9090
   Nhớ tắt khi xong:
     networksetup -setwebproxystate       Wi-Fi off
     networksetup -setsecurewebproxystate Wi-Fi off

GỠ
- Xoá app.
- Keychain Access -> login -> xoá "ProxyManClone Root CA".
  App chưa có nút gỡ CA; phải làm tay.
- rm -rf ~/Library/Application\ Support/ProxyManClone

GIỚI HẠN ĐÃ BIẾT
- Mọi kết nối bị ép xuống HTTP/1.1 (ALPN chỉ quảng cáo http/1.1).
- Chưa hỗ trợ WebSocket.
- Body nén brotli/zstd chưa giải nén được; bật "Ép server không nén".
- App pin certificate sẽ hỏng khi bị MitM — đó là lý do có bypass list.
README

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Đã tạo $DMG ($(du -h "$DMG" | cut -f1))"
