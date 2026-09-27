# Tự động đặt/gỡ proxy hệ thống — Thiết kế

Ngày: 2026-09-28
Trạng thái: đã duyệt thiết kế, chưa lập plan

## 1. Vấn đề

App bind proxy ở `127.0.0.1:9090` nhưng **không đụng gì tới cài đặt proxy của
macOS**. Người dùng phải tự gõ `networksetup` để bật, và tự nhớ gõ lại để tắt.

Hậu quả đã xảy ra thật trên máy người dùng, hai lần:

1. App bị thoát trong khi proxy hệ thống vẫn bật trỏ `127.0.0.1:9090`. Cổng đó
   không còn ai nghe, nên **mọi ứng dụng tôn trọng proxy hệ thống đều mất
   mạng**. Lần đó nạn nhân là Citrix Workspace, và phải mất một vòng chẩn đoán
   sai mới lần ra.
2. Proxy được bật trên Wi-Fi trong khi dịch vụ mạng chính là VPN. macOS chỉ áp
   dụng cấu hình của **dịch vụ chính**, nên cài đặt đó nằm im. App im lặng
   không bắt được gì, không báo gì, và người dùng tưởng app hỏng.

Proxyman và Charles đều tự quản việc này. Đó là lý do người dùng của chúng
không bao giờ gặp hai cảnh trên.

### Phi mục tiêu

- Không quản proxy SOCKS, FTP, Gopher, hay PAC URL. Chỉ HTTP và HTTPS.
- Không sửa bypass domains.
- Không hỗ trợ cấu hình proxy của thiết bị khác (iPhone, Simulator) — những
  thứ đó nằm ngoài tầm với của app.
- Không tự bật VPN/Wi-Fi hay đổi route.

## 2. Bốn quyết định, và lý do

### 2.1 Đặt lên TẤT CẢ dịch vụ đang hoạt động, không chỉ dịch vụ chính

macOS chỉ đọc cấu hình proxy của dịch vụ chính, nhưng **dịch vụ nào là chính
thì đổi theo thời gian** — bật VPN là đổi, rút cáp là đổi, ngủ dậy là đổi.

Đặt lên tất cả khiến câu hỏi "cái nào đang là chính" biến mất khỏi thiết kế.
Bật/tắt VPN giữa phiên vẫn bắt được, không cần làm gì, không cần theo dõi
`SCDynamicStore`. Đây cũng là cách Proxyman/Charles làm.

Đánh đổi: có đụng vào dịch vụ người dùng đang không dùng. Chấp nhận được vì
mọi dịch vụ đều được trả lại đúng trạng thái cũ, và vì phương án thay thế
(bám theo dịch vụ chính) thêm một luồng sự kiện sống suốt phiên cùng một cửa
sổ tranh chấp khó đóng kín: đổi mạng ngay giữa lúc đang chuyển.

### 2.2 Khôi phục sau crash bằng file snapshot, không bằng tiến trình canh

Không có cách nào chạy code sau `SIGKILL`. Đây là giới hạn của hệ điều hành,
không phải của thiết kế, nên mọi phương án đều phải chừa lại một lỗ hổng.

Chọn lỗ hổng rẻ nhất: ghi trạng thái cũ ra file trước khi đổi, và khôi phục ở
**lần mở app sau**. Không thêm binary, không thêm vòng đời phải tự quản.

Lỗ hổng còn lại: từ lúc crash tới lúc mở lại app, máy vẫn mất mạng. Chấp nhận
vì app chính là thứ người dùng sẽ nghi đầu tiên khi mất mạng ngay sau khi dùng
nó — và vì một tiến trình canh cũng có thể chết theo cách y hệt, chỉ là đẩy
cùng một lỗ hổng lùi thêm một lớp.

### 2.3 Proxy cũ trỏ vào chính app → ghi nhận là "tắt"

Nếu chụp trạng thái một cách trung thực tuyệt đối, cái mớ cũ đang có sẵn trên
máy (Wi-Fi bật, trỏ `127.0.0.1:9090`) sẽ bị đóng băng thành "nguyên bản", và
mỗi lần Dừng app lại đặt máy về đúng trạng thái mất mạng. Tính năng sinh ra để
sửa lỗi đó sẽ tự tái tạo nó vĩnh viễn.

Luật: thấy `enabled && server là loopback && port == cổng app sắp đặt` thì ghi
vào snapshot là `enabled: false`. Điều kiện **phải khớp cả cổng**: một Charles
đang chạy ở `127.0.0.1:8888` cũng là loopback nhưng không phải dấu vết của ta,
và gỡ mất nó là một kiểu phá hoại khác, khó lần ra hơn.

"Loopback" ở đây định nghĩa hẹp và tường minh, không suy đoán: đúng một trong
ba chuỗi `127.0.0.1`, `::1`, `localhost` (không phân biệt hoa thường). Không
nhận cả dải `127.0.0.0/8`: một người cố tình đặt proxy ở `127.0.0.2` là đang
trỏ vào thứ khác, không phải vào ta.

### 2.4 Toggle riêng, mặc định BẬT

Người chỉ muốn bắt traffic iPhone (đã có toggle LAN cho việc đó) không có lý
do gì để máy Mac của mình bị kéo vào. Traffic của chính Mac lẫn vào bảng còn
làm nhiễu đúng thứ họ đang muốn xem.

Mặc định BẬT vì đó là trường hợp thường gặp hơn. Tắt toggle giữa chừng là gỡ
proxy ngay, không cần bấm Dừng.

Toggle **không lưu qua các lần mở app** — mỗi lần mở lại là BẬT. Giống hệt
`allowLANDevices` và `forceDecompressible` đang có, nên không sinh thêm một
kiểu trạng thái mới để người đọc code phải nhớ. Với một công tắc thay đổi cài
đặt mạng toàn máy, mặc định về giá trị đã biết mỗi lần mở cũng an toàn hơn là
âm thầm khôi phục lựa chọn cũ của phiên trước.

## 3. Module và kiểu dữ liệu

Target mới `SystemProxy`, ngang hàng `CertKit`. Chỉ phụ thuộc Foundation,
không biết gì về proxy engine hay UI.

Tách riêng chứ không nhét vào `AppCore` vì đây là một năng lực hệ thống độc
lập, test được riêng, và `AppModel.swift` đã đủ dài.

```swift
public struct ProxySetting: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var server: String
    public var port: Int
}

public struct ServiceProxySnapshot: Sendable, Equatable, Codable {
    public var service: String        // "Wi-Fi", "phuoc.kieu-c-sg"
    public var web: ProxySetting      // HTTP
    public var secureWeb: ProxySetting
}

public struct ProxySnapshot: Sendable, Equatable, Codable {
    public var takenAt: Date
    public var appliedHost: String    // "127.0.0.1"
    public var appliedPort: Int       // dùng để nhận ra dấu vết của chính mình
    public var services: [ServiceProxySnapshot]
}
```

Ba lớp, mỗi lớp một việc:

| Lớp | Việc | Phụ thuộc |
| --- | --- | --- |
| `SystemProxyConfiguring` (protocol) | liệt kê dịch vụ, đọc, đặt, trả lại — **một dịch vụ mỗi lần** | — |
| `NetworkSetupConfigurer` | hiện thực bằng `networksetup`, qua runner tiêm được | `CommandRunner` |
| `SystemProxyController` (actor) | điều phối nhiều dịch vụ, quản file snapshot, chuẩn hoá | hai lớp trên |

`CommandRunner` khai báo lại trong target này chứ không mượn của `CertKit`:
cert và proxy không liên quan gì nhau, nối hai module lại chỉ để tiết kiệm một
dòng `typealias` là nối sai.

### 3.1 Một ràng buộc định hình interface

`applicationWillTerminate` là hàm **đồng bộ** — trả về xong là app chết, một
`Task` async bên trong sẽ không kịp chạy.

Nên `SystemProxyController` phải có thêm một đường khôi phục **đồng bộ**, dùng
chung code dựng lệnh với đường async. Đây là ràng buộc lên hình dạng interface
chứ không phải chi tiết hiện thực, nên nó thuộc về mục này.

### 3.2 Vị trí file snapshot

`~/Library/Application Support/ProxyManClone/system-proxy-snapshot.json`

Cùng thư mục với `ca/`, nên không thêm chỗ mới nào để người dùng phải biết.

## 4. Luồng dữ liệu

### 4.1 Bật (sau khi bind thành công, nếu toggle đang bật)

1. `-listallnetworkservices` → bỏ dịch vụ có dấu `*` đầu tên (đang tắt)
2. Mỗi dịch vụ: đọc `-getwebproxy` và `-getsecurewebproxy`
3. Chuẩn hoá theo luật §2.3
4. **Ghi file snapshot xuống đĩa, `fsync`, rồi mới đổi bất cứ thứ gì**
5. Mỗi dịch vụ: `-setwebproxy` và `-setsecurewebproxy` về `127.0.0.1:<port>`

Cổng dùng ở bước 5 là cổng **thật sự bind được**, lấy từ giá trị trả về của
`ProxyServer.start()`, không phải cổng trong cấu hình — hai giá trị đó khác
nhau khi cấu hình dùng cổng 0.

**Thứ tự 4 trước 5 là cốt lõi của toàn bộ thiết kế.** Crash giữa bước 5 thì
file đã mô tả đủ *mọi* dịch vụ ta định đụng vào, kể cả cái chưa kịp đụng.
Khôi phục thừa thì vô hại — ghi lại đúng giá trị đang có. Khôi phục thiếu thì
mất mạng. Ngược thứ tự lại là tạo ra một cửa sổ nằm đúng giữa "đã đổi" và "đã
lưu"; rơi vào đó là mất sạch đường về.

### 4.2 Tắt (Dừng, tắt toggle, hoặc thoát app)

Đọc file → khôi phục từng dịch vụ → xoá file, **chỉ khi tất cả thành công**.

Hỏng cái nào thì giữ file và báo lỗi; lần mở sau sẽ thử lại. Xoá file lúc chưa
khôi phục xong là vứt mất bản đồ đường về.

### 4.3 Khôi phục lúc mở app

Chạy **trước khi vẽ cửa sổ**. Thấy file còn sót nghĩa là lần trước chết bất
thường.

### 4.4 Luật áp dụng cho cả ba luồng

> Chỉ khôi phục dịch vụ mà cấu hình **hiện tại vẫn đang trỏ vào ta**. Ai đã
> đổi đi chỗ khác thì để yên.

Không có luật này thì kịch bản sau làm hỏng việc thật: app crash → người dùng
mất mạng → họ tự vào đặt proxy công ty → mở lại app → app lẳng lặng đạp mất
cấu hình vừa đặt, viện cớ "khôi phục". Ý muốn mới của người dùng phải thắng
dấu vết cũ của ta.

Luật này cũng làm việc khôi phục trở nên **idempotent**: chạy lại bao nhiêu
lần cũng không hại.

### 4.5 Tương tác với `restartIfRunning()`

Đổi toggle LAN hoặc toggle nén sẽ đi qua `stop()` → `start()`, tức tắt rồi bật
lại proxy hệ thống. Không sinh lỗi: giữa hai bước máy đã ở trạng thái nguyên
bản, nên ảnh chụp lần hai vẫn đúng.

## 5. Xử lý lỗi

Nguyên tắc: mỗi đường hỏng phải kết thúc ở một trạng thái người dùng tự cứu
được, không bao giờ ở chỗ app im lặng.

### 5.1 Đặt hỏng giữa chừng

Lùi lại những dịch vụ đã đặt, dùng chính file snapshot vừa ghi. Proxy engine
**vẫn chạy** — nó đã bind rồi và vẫn dùng được qua cờ `--proxy-server` hoặc
cấu hình tay.

Toggle bật về tắt: toggle phải phản ánh **thực tế**, không phản ánh ý định.
`statusMessage` nói rõ hỏng ở dịch vụ nào.

### 5.2 Khôi phục hỏng giữa chừng

Đây là trạng thái mất mạng, nên nó phải ồn. Giữ file, báo lỗi rõ ràng, và **in
ra đúng lệnh cần gõ** để người dùng tự gỡ.

Một app làm người dùng mất mạng mà chỉ nói "đã xảy ra lỗi" thì tệ hơn là không
có tính năng này.

### 5.3 File snapshot hỏng hoặc không đọc được

Không xoá. Có một đường cứu không cần tới file:

> Tắt proxy trên mọi dịch vụ mà cấu hình hiện tại đang trỏ `127.0.0.1` đúng
> cổng app dùng.

Dấu vết đó chắc chắn do ta để lại, nên tắt nó an toàn kể cả khi không biết
trạng thái gốc. Proxy của người khác không bị đụng. Không đoán gì thêm ngoài
phạm vi đó.

### 5.4 `networksetup` bị từ chối quyền

Bắt exit code khác 0, báo nguyên văn output.

### 5.5 Lúc thoát app

Đường đồng bộ, không `await`. Hỏng thì chỉ ghi log — lần mở sau sẽ dọn.

## 6. Chiến lược test

### 6.1 Test được bằng runner giả

| # | Khẳng định |
| --- | --- |
| 1 | Parse `-listallnetworkservices`, bỏ dịch vụ có `*`; tên có dấu chấm/gạch (`phuoc.kieu-c-sg`) không vỡ |
| 2 | Parse `-getwebproxy` → `ProxySetting` |
| 3 | Chuẩn hoá đúng cổng ta → `enabled:false`; khác cổng (Charles 8888) thì giữ nguyên |
| 4 | File snapshot tồn tại **trước** lệnh `set` đầu tiên — runner giả ghi timeline rồi assert |
| 5 | Lệnh `set` thứ hai ném lỗi → dịch vụ đã đặt được lùi lại |
| 6 | Restore bỏ qua dịch vụ đã bị đổi sang chỗ khác |
| 7 | Restore hỏng → file **không** bị xoá; restore xong → file bị xoá |
| 8 | Mở app không có file sót → **không chạy lệnh nào** |
| 9 | JSON hỏng → đi đường cứu, chỉ tắt dịch vụ đang trỏ vào ta |
| 10 | `ProxySnapshot` round-trip qua `Codable` |

### 6.2 Không test nào chứng minh được

- `networksetup` có ghi được **từ trong app bundle GUI** không
- Có bật hộp thoại xin quyền không
- `applicationWillTerminate` có kịp chạy xong đường đồng bộ trước khi bị giết
- `DispatchSource` có thật bắt được `SIGTERM` từ Activity Monitor không
- Hành vi khi dịch vụ mạng biến mất giữa chừng (rút cáp, VPN sập)

Ba lỗi nặng nhất của dự án này — `TabView` không vẽ thanh tab, cây JSON thu
gọn hết, và §6.3 Root CA — **đều qua sạch toàn bộ test**. Danh sách dưới đây
không phải thủ tục cho có.

### 6.3 Kiểm thủ công bắt buộc

Mỗi mục là một câu quan sát được, không phải "kiểm tra xem có chạy không".

- **M1 (spike, làm trước mọi thứ khác):** mở từ `.app`, bấm Chạy → Terminal
  `networksetup -getwebproxy Wi-Fi` phải ra `Enabled: Yes`, `127.0.0.1`,
  `9090`, và **không hiện hộp thoại mật khẩu nào**
- **M2:** bấm Dừng → `Enabled: No`
- **M3:** ⌘Q khi đang chạy → proxy tắt
- **M4:** `kill -9` khi đang chạy → proxy còn bật; mở lại app → tắt **trước
  khi cửa sổ hiện**
- **M5:** bật VPN giữa chừng → Chrome vẫn lên traffic, không phải làm gì
- **M6:** tự đổi proxy sang `127.0.0.1:8888` lúc app đang chạy → Dừng → app
  **không** đạp giá trị đó
- **M7:** máy đang có sẵn mớ cũ (Wi-Fi bật 9090) → Chạy → Dừng → phải về
  `Enabled: No`, **không** về 9090

M7 chính là tình trạng máy người dùng lúc viết spec này, nên nó vừa là test
vừa là lần dọn dẹp thật.

## 7. Rủi ro

### 7.1 `networksetup` có ghi được từ app GUI không — rủi ro hình dạng §6.3

Spec MVP §6.3 thiết kế việc cài Root CA vào System keychain qua `osascript`
chạy dưới quyền root. Nó **chưa từng chạy được từ app GUI trên bất kỳ máy
nào**, vì `add-trusted-cert -d` cần một hộp thoại authorization mà tiến trình
root không hiện được. Không review nào bắt được; chỉ người dùng mang sang máy
khác mới lòi ra.

Rủi ro ở đây cùng hình dạng: `networksetup` chạy ngon trong Terminal dưới tài
khoản admin **không đảm bảo** chạy ngon từ trong một app bundle ad-hoc sign.

Giảm thiểu: **M1 là việc đầu tiên trong plan**, trước khi xây bất cứ thứ gì
khác. Nếu M1 thất bại thì cả thiết kế này phải xem lại — và biết điều đó ở
ngày đầu rẻ hơn hẳn biết ở ngày cuối.

### 7.2 Thời gian trong `applicationWillTerminate`

macOS không hứa cho bao lâu trước khi giết app. Đường khôi phục đồng bộ chạy
`networksetup` một lần cho mỗi dịch vụ (2 lệnh × N dịch vụ), mỗi lệnh vài chục
ms. Với 4 dịch vụ là khoảng 8 tiến trình.

Nếu M3 cho thấy không kịp: cân nhắc `applicationShouldTerminate` trả
`.terminateLater` rồi gọi `replyToApplicationShouldTerminate(true)` sau khi
xong. Không thiết kế sẵn cho tình huống đó — đo trước đã.

### 7.3 Dịch vụ mạng biến mất giữa phiên

Rút cáp hoặc VPN sập thì tên dịch vụ vẫn còn trong danh sách nhưng thành
inactive. Lệnh `set`/`get` lên nó có thể lỗi.

Xử lý theo §5.1/§5.2: lỗi trên một dịch vụ không làm hỏng các dịch vụ còn
lại, và file snapshot vẫn giữ nguyên thông tin của nó cho lần khôi phục sau.

## 8. Sau tính năng này

- Nút/menu "Gỡ proxy ngay" để tự cứu khi rơi vào trạng thái lạ — đã cân nhắc,
  gạt ra khỏi phạm vi lần này để giữ bề mặt nhỏ.
- Hiện trong thanh trạng thái danh sách dịch vụ đang bị đặt proxy.
- Doc comment của `SecurityCommandInstaller` còn mô tả đường osascript/root đã
  bị xoá ở commit `0f1340a`. Nợ kỹ thuật có sẵn, không thuộc phạm vi lần này.
