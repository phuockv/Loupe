# Nhật ký quyết định — MVP ProxyManClone

Ngày: 2026-09-05 → 2026-09-06. Nhánh `feat/mvp`, 34 commit, 149 test.

Tài liệu này ghi lại **mọi quyết định tôi (Claude) đưa ra thay mặt bạn** trong quá trình
thực thi plan, kèm cái giá phải trả nếu quyết định đó sai. Đọc và đảo ngược bất cứ mục nào bạn không đồng ý.

Bối cảnh chung: plan dài 3.800 dòng viết trong một lượt. Vòng review bắt được **hơn ba mươi lỗi thật**,
và gần như tất cả đều sinh ra từ code tham chiếu trong plan chứ không phải từ công việc của các implementer.
Hai chủng lỗi lặp lại nhiều nhất: (1) byte được ghi vào một channel âm thầm vứt nó đi, trong khi transaction
vẫn báo hoàn chỉnh — *công cụ nói dối*; (2) một doc comment khẳng định bất biến mà code không hề giữ.

---

## Rulings (60)

**R1 — Pre-flight.** F1 — `TrafficEvent` không có case nào mang request body về UI, nên inspector sẽ luôn hiện "Không có body" ở tab Request. `.started` phát lúc `.head` (body chưa có) và `.completed` chỉ mang response; `finishRequestBody()` chỉ sửa bản sao phía engine, không bao giờ phát lại. Spec §7.3 bắt buộc tab Request có mục Body, nên đây là lỗi plan thật. Quyết: thêm case `.requestBody(id: UUID, BodyPayload)` vào TrafficEvent (T2), phát nó trong `HTTPProxyHandler.finishRequestBody()` (T6), xử lý trong `TrafficStore.apply` (T10). Không chuyển `.started` sang phát lúc `.end` vì như vậy request đang chạy sẽ không hiện ra — mất hẳn tính chất xem traffic trực tiếp. — Cost nếu sai: thừa một case enum, gỡ ra rất rẻ.

**R2 — Pre-flight.** F2 — T8 Step 1 viết "Thêm property và tham số init" nhưng đoạn code chỉ thêm stored property có giá trị mặc định. Property-only là đúng và đủ: init của T5 là explicit, Swift cho phép stored property có default mà không cần nằm trong init, và test set qua `config.additionalTrustRoots = [...]`. Quyết: chỉ thêm property, bỏ qua chữ "và tham số init". — Cost nếu sai: không có.

**R3 — Pre-flight.** F3 — test tunnel của T7 chỉ assert `socket.isActive` và nội dung transaction, không assert byte có thực sự đi vòng qua echo server và quay về. Một test mang tên "relay byte thô" mà không kiểm việc relay thì gần như vô nghĩa. Quyết: T7 phải gắn thêm một handler thu byte vào client channel và assert nhận lại đúng payload đã gửi. — Cost nếu sai: test dài thêm ~15 dòng.

**R4 — Pre-flight.** F4 — trong `ProxyErrorHandlingTests`, biểu thức dựng `caPath` qua `#require((try? ...).map { _ in ... })` là vòng vèo vô nghĩa. `CertificateAuthority.loadOrCreate(in: dir)` đã ghi sẵn `ca.pem` vào `dir`. Quyết: `makeServer` trả thêm `dir`, test dùng thẳng `dir.appendingPathComponent("ca.pem")`. — Cost nếu sai: chỉ là thẩm mỹ test.

**R5 — Pre-flight.** F5 — test cert pinning dùng `https://example.com/`. Đường đi thực tế không hề gọi ra mạng (handshake với client hỏng trước khi có request nào để forward), nhưng dùng tên miền thật khiến người đọc không chắc điều đó. Quyết: đổi sang `https://pinning-test.invalid/` — TLD `.invalid` không bao giờ resolve, và với `-x` thì curl để proxy tự resolve. — Cost nếu sai: không có.

**R6 — Pre-flight.** F6 — `SecurityCommandInstaller(runner: captured.run)` truyền một method của actor vào `@Sendable ([String]) async throws -> String`. Về lý thuyết hợp lệ (non-throwing chuyển được sang throwing, actor là Sendable) nhưng Swift 6 strict concurrency có thể từ chối. Quyết: nếu không biên dịch được thì bọc lại thành `{ try await captured.run($0) }`, không đổi thiết kế. — Cost nếu sai: không có.

**R7 — Pre-flight.** F7 — `AppModel.installCertificate()` có dòng `_ = try authority.certificatePEM()` không dùng vào việc gì; `loadOrCreate` đã ghi ca.pem ra đĩa rồi. Quyết: xoá dòng đó. — Cost nếu sai: không có.

**R8 — Task 1.** spike trả DER true → Task 4 dùng `NIOSSLPrivateKey(bytes: Array(leafKey.derRepresentation), format: .der)`, bỏ hẳn nhánh .pem dự phòng và bỏ luôn Step 5 của Task 4 (không còn gì để chuyển đổi). Rủi ro 11.1 của spec đóng lại. — Cost nếu sai: quay về .pem, một dòng.

**R9 — Task 1.** implementer thay `defer { try? group.syncShutdownGracefully() }` bằng cleanup async-safe vì API đó là @available(*, noasync) và không biên dịch trong async test. Chấp nhận — ràng buộc toolchain thật, không phải lựa chọn tuỳ tiện. Task reviewer được giao kiểm riêng việc cleanup mới có làm yếu assertion của spike không. — Cost nếu sai: spike chứng minh hụt, reviewer sẽ bắt.

**R10 — Task 1.** Important #1 (test handshake chỉ assert `client.isActive`, mà cái đó là trạng thái TCP chứ không phải TLS đã handshake xong — `connect().get()` resolve ngay khi TCP nối được, ClientHello/ServerHello diễn ra sau) là ĐÚNG và là lỗi tôi viết trong plan. Plan Step 6 tự nhận "nạp được vào type chưa chứng minh handshake chạy" rồi lại viết một test không chứng minh được điều đó. Kết luận DER/PEM vẫn đứng vững vì nó đến từ constructor throwing, nhưng test thứ ba thất bại đúng mục đích của chính nó. Quyết: vào fix loop round 1, siết lại bằng round-trip dữ liệu thật hoặc chờ TLSUserEvent.handshakeCompleted. — Cost nếu sai: một test chặt hơn mức cần, vô hại.

**R11 — Task 1.** Important #2 (cảnh báo `conformance of 'NIOSSLHandler' to 'Sendable' is unavailable`) — có thật, nhưng phát sinh từ annotation của chính swift-nio-ssl, không phải thứ caller sửa được. Quyết: KHÔNG fix ở Task 1; park lại và mang sang brief của Task 6 như rủi ro đã biết, vì Task 6 là nơi đầu tiên code production dựng NIOSSL handler trong closure @Sendable. Nếu ở đó nó thành error chứ không phải warning thì mới là vấn đề thật. — Cost nếu sai: Task 6 gặp bất ngờ về strict concurrency, mất một vòng fix.

**R12 — Task 1.** gộp 2 Minor rẻ (CertKitTests thiếu khai báo Crypto/SwiftASN1/X509; Package.resolved untracked) vào round 1 đang mở sẵn. Luật "minor không vào loop" là để minor không TẠO hay KÉO DÀI loop — round này đã mở vì Important #1, mỗi minor là một dòng Package.swift. — Cost nếu sai: không có.

**R13 — Task 2.** Important #1 (RequestModel.url là `var` nên queryItems dẫn xuất một lần có thể lệch) — finding ĐÚNG, spec §4 ghi rõ "Suy ra từ url lúc dựng, không cho set riêng — tránh hai nguồn sự thật lệch nhau", tức spec cấm drift còn code lại cho phép. Spec là authority → finding thắng plan text. Quyết: đổi `url` thành `let`. Không chỗ nào trong Task 6/8 cần mutate url (đều dựng RequestModel mới), nên `let` không phá gì. — Cost nếu sai: nếu sau này thật sự cần đổi url tại chỗ thì phải dựng lại struct, đúng cách cho value type.

**R14 — Task 2.** Important #2 (write(_:) hỏng giữa chừng làm mất byte đã spill và bỏ rơi file tạm) — finding ĐÚNG và nặng hơn mức implementer tự khai. Tự truy lại: startSpilling xoá buffer sau khi ghi ra đĩa; write() hỏng thì nil fileURL mà không xoá file → file mồ côi vĩnh viễn (Task 10 chỉ xoá payload .file, .truncated không đụng tới). Tệ hơn: guard !spillFailed nằm ở nhánh thứ ba nên append nhỏ sau đó vẫn lọt vào buffer rỗng → .truncated trả về byte ĐUÔI trong khi spec §4 và doc comment của chính nó hứa "giữ 2 MB ĐẦU". Spec là authority → finding thắng. Quyết: (a) chuyển guard !spillFailed lên đầu append để sau khi hỏng chỉ còn đếm byte, (b) xoá file dở trước khi nil fileURL. Kết quả: startSpilling hỏng → giữ đúng phần đầu; write hỏng giữa chừng → .truncated(rỗng, totalBytes thật), trung thực và không rò file. Không giữ snapshot 2MB trong RAM để cứu phần đầu — làm vậy là phá đúng mục đích của spill. — Cost nếu sai: mất phần đầu body trong đúng tình huống đĩa đầy giữa chừng; đổi lại không rò file và không nói dối về nội dung.

**R15 — Task 3.** Important #1 (loadOrCreate chỉ nạp lại khi CẢ HAI file tồn tại; nếu chỉ còn một thì âm thầm generate + ghi đè cả hai) — finding ĐÚNG và là kịch bản nguy hiểm nhất trong task này. Hậu quả thực tế: người dùng đã trust CA cũ trong System keychain, app âm thầm thay CA mới, mọi kết nối MitM ký bằng CA máy không tin → lỗi TLS khó hiểu chứ không phải thông báo rõ. Không có backup, không có tín hiệu. Quyết: chỉ generate khi KHÔNG file nào tồn tại; nếu tồn tại đúng một file thì ném lỗi riêng, thông điệp nói rõ file nào thiếu và người dùng phải làm gì. — Cost nếu sai: người dùng gặp lỗi thay vì app tự phục hồi, nhưng "tự phục hồi" ở đây chính là thứ phá trust store của họ.

**R16 — Task 3.** Important #2 (không đối chiếu ca.pem với ca.key.pem lúc nạp) — finding ĐÚNG. Hai file parse được riêng lẻ nhưng không khớp nhau sẽ tạo ra CertificateAuthority mà signingKey không ký hợp lệ cho certificate; lỗi chỉ lộ ra ở Task 4 dưới dạng mù mờ. Quyết: so publicKey của khoá với publicKey của cert lúc nạp, lệch thì ném cùng loại lỗi ở #1. — Cost nếu sai: thêm một phép so sánh rẻ trên đường khởi động.

**R17 — Task 4.** giữ identityCache dù nó vượt quá brief. Lý do: identity(forHost:) nằm trên đường nóng của MỌI kết nối HTTPS (Task 8 gọi mỗi CONNECT), và code brief serialize DER + dựng NIOSSLCertificate lại mỗi lần gọi. Reviewer đã xác minh hai cache evict đồng bộ với mọi capacity >= 1. Gỡ nó ra để thoả mãn cách đọc chữ nghĩa sẽ cho ra code tệ hơn. ❌ này được giải bằng ruling, không phải bằng việc sửa. — Cost nếu sai: thêm một bất biến phải giữ giữa hai dictionary trong cùng một file 101 dòng.

**R18 — Task 4.** vì tôi CHỌN giữ cache thứ hai, tôi nhận luôn bất biến nó tạo ra. Reviewer tìm được đường rò ở capacity <= 0 (host vừa mint bị evict ngay trong certificate(), rồi identity() ghi vào identityCache sau đó nên không bao giờ evict được). Hiện không call site nào chạm tới, nhưng defer một rủi ro do chính ruling của mình sinh ra là không trung thực. Quyết: mở fix round nhỏ thêm guard capacity >= 1. — Cost nếu sai: một dòng precondition thừa.

**R19 — Task 5.** Important #1 (sanitize không đọc giá trị Connection để strip các header mà nó liệt kê, RFC 9110 §7.6.1) — finding ĐÚNG. Doc comment của tôi trích thẳng §7.6.1 nhưng chỉ làm nửa tĩnh của điều khoản. Quyết: implement nốt nửa còn lại (~5 dòng) thay vì hạ cấp comment. Hoặc tuân thủ, hoặc đừng tuyên bố tuân thủ. — Cost nếu sai: strip nhầm một header mà server đích cần, hiếm và lộ ngay.

**R20 — Task 5.** Important #2 (không kiểm dải port; "example.com:99999" → 99999, "example.com:-443" → -443) — finding ĐÚNG. Task 6/7 đem số này đi dial socket, Task 8 đem host đi mint cert. Quyết: validate 1...65535, ngoài dải trả nil. — Cost nếu sai: từ chối một target hợp lệ mà tôi chưa nghĩ ra, nhưng ngoài 1..65535 thì không có target hợp lệ nào.

**R21 — Task 5.** Important #3 (IPv6 hỏng: "[::1" thiếu ngoặc đóng → trả ("[:", 1) thay vì nil) — finding ĐÚNG và nguy hiểm nhất trong bốn cái, vì Task 8 lấy đúng host đó đi mint certificate. Heuristic của tôi chỉ kiểm hasSuffix("]") mà không kiểm ngoặc mở khớp. Quyết: yêu cầu ngoặc khớp, không khớp thì nil. — Cost nếu sai: từ chối một dạng literal hợp lệ, sẽ lộ ngay khi dùng.

**R22 — Task 5.** Important #4 (isBypassed sai âm với FQDN có dấu chấm cuối: "apple.com." không khớp "apple.com") — finding ĐÚNG. Dấu chấm cuối là cú pháp DNS hợp lệ. Sai âm ở đây nghĩa là proxy MitM một host lẽ ra phải tunnel mù → làm hỏng app pin cert, đúng chế độ hỏng tệ nhất. Quyết: cắt dấu chấm cuối trước khi so; gộp luôn minor lowercase cho phần tử trong bypassedHosts. — Cost nếu sai: không có.

**R23 — Task 6.** design gap #1 (finishRequestBody dùng state.pendingIDs.first — id của request CŨ NHẤT chưa có response, không phải request vừa xong body) — finding ĐÚNG. Với HTTP/1.1 pipelining, pendingIDs có thể là [req1, req2] lúc body req2 xong, và .first gán body req2 vào transaction req1. Quyết: fix — HTTPProxyHandler giữ riêng id của request đang nhận body, đặt lúc .head, dùng lúc finishRequestBody. — Cost nếu sai: thêm một thuộc tính; client hiếm khi pipeline nên rủi ro thấp, nhưng gán sai dữ liệu vào transaction là kiểu lỗi làm công cụ nói dối.

**R24 — Task 6.** design gap #2 (byte body tới TRƯỚC khi connectUpstream resolve bị vứt im lặng — upstream?.write là no-op khi upstream còn nil) — finding ĐÚNG và đây là lỗi nghiêm trọng nhất tìm được từ đầu dự án. Mọi POST/PUT có body stream vào trong lúc TCP handshake tới origin còn dang dở sẽ tạo ra request BỊ CẮT CỤT trên dây, trong khi transaction proxy ghi lại trông hoàn chỉnh và đúng. Với một công cụ debug thì đây là chế độ hỏng tệ nhất: nó nói dối người dùng về thứ nó vừa gửi đi. Quyết: fix — đệm các phần request (head/body/end) cho tới khi upstream connect xong rồi replay đúng thứ tự. — Cost nếu sai: thêm bộ đệm giới hạn theo maxInMemoryBodyBytes; không sửa thì proxy âm thầm làm hỏng mọi upload.

**R25 — Task 6.** CRITICAL (connectUpstream đóng channel cũ nhưng KHÔNG nil upstream; forwardOrBuffer chỉ kiểm `if let upstream` chứ không kiểm isActive) — finding ĐÚNG và đây chính là lỗi mà fix round trước sinh ra để diệt, sống sót trên nhánh anh em. Hai đường tới rất tầm thường: request thứ hai trên cùng client connection trỏ host khác (browser/URLSession tái dùng connection tới proxy), hoặc cùng host sau khi origin đóng keep-alive. Content-Length vẫn được forward nên origin treo chờ body không bao giờ tới, còn transaction ghi lại vẫn trông hoàn chỉnh. Quyết: fix, nil cả upstream lẫn upstreamTarget ngay sau close. — Cost nếu sai: không có, đây là bug thuần.

**R26 — Task 6.** Important #2 (đóng channel cũ làm UpstreamHandler cũ drain sạch pendingIDs, phát .failed cho transaction vừa enqueue 3 dòng trước, rồi .completed không bao giờ tới) — ĐÚNG, cùng chỗ sửa với Critical.

**R27 — Task 6.** Important #3 (client ngắt trong lúc connect: NIOLoopBoundBox giữ handler sống, connect xong vẫn gửi request đi và rò socket vì channelInactive đã chạy rồi) — ĐÚNG. Quyết: đặt cờ client-gone trong channelInactive.

**R28 — Task 6.** Important #4 (SessionState.dequeue xoá khỏi pendingIDs nhưng không xoá khỏi transactions → mỗi keep-alive connection tích luỹ toàn bộ transaction kèm body tới 2 MiB) — ĐÚNG, plan-mandated, một dòng.

**R29 — Task 6.** NÂNG Minor #6 lên bắt buộc — cap buffer 2 MiB có thể 502 oan mọi upload lớn hơn 2 MiB trong production, vì phần body tới trong lúc connect (10-100ms tới origin thật) dễ vượt cap. Lý do implementer từ chối autoRead là SAI (nó nói NIO giao hết message trong một read(), nhưng thực tế bị chặn bởi maxMessagesPerRead × recv buffer, thấp hơn 2 MiB rất nhiều). Quyết: bắt buộc làm nốt nửa autoRead backpressure. — Cost nếu sai: phức tạp thêm một chút ở chỗ bật/tắt read; không làm thì app hỏng ngay khi ai đó upload file 3 MB.

**R30 — Task 6.** Minor #10 (HTTPProxyHandler không conform RemovableChannelHandler và không nằm trong httpHandlers) là forward-blocker cho Task 7 — gộp vào round này thay vì để Task 7 vấp.

**R31 — Task 6.** KHÔNG đóng round khi Critical chưa có test. Lỗi ghi-vào-upstream-đã-chết này đã xuất hiện HAI LẦN ở cùng vùng code — lần một là in-flight connect (round 1), lần hai là connection reuse (round 2). Một bug hỏng-dữ-liệu-âm-thầm tái phát hai lần mà sửa không kèm test thì gần như chắc chắn có lần ba, và lần ba sẽ không ai bắt vì Task 7/8 đã chồng lên trên. Quyết: bắt bổ sung test hồi quy cho nhánh đổi host trước khi re-review; nhánh client-ngắt thì nới, vì dựng deterministic tốn hơn giá trị. — Cost nếu sai: thêm một integration test ~40 dòng.

**R32 — Task 6.** câu hỏi "lần thứ ba" có câu trả lời TRUNG THỰC và là "chưa đóng". Hai instance đã biết bị chặn về mặt cấu trúc (upstream chỉ set ở một chỗ, clear ở hai chỗ), NHƯNG forwardOrBuffer vẫn chỉ kiểm `if let upstream` chứ không kiểm isActive — liveness được xác thực lúc nhận head rồi không bao giờ kiểm lại. Cửa sổ còn lại: upstream chết giữa head và .end → body ghi vào channel chết và bị nuốt. Hệ quả nhẹ hơn hai lần trước (UpstreamHandler vẫn phát .failed nên bản ghi KHÔNG nói dối là hoàn chỉnh) nhưng client bị treo: không ai ghi 502, không ai đóng client channel. Quyết: mở round 3 để đóng lớp bug này về mặt cấu trúc chứ không phải vá từng instance. Lý do: bug class này đã tái phát HAI lần, Task 7/8 sắp thêm đường mới vào cùng hàm, và chi phí đóng hẳn là một guard + một else branch. — Cost nếu sai: thêm một nhánh lỗi hiếm khi chạy.

**R33 — Task 6.** gộp 2 minor rẻ vào round 3 (isUpstreamReusable thiếu mệnh đề scheme; event drain trong test mới không có timeout nên regression tương lai sẽ TREO thay vì đỏ). Minor thứ ba (handlerRemoved cho Task 7) chuyển sang brief Task 7 vì đó là nơi việc gỡ handler thực sự xảy ra.

**R34 — Task 6.** chấp nhận toàn bộ. Fix cấu trúc là gom cả hai chỗ ghi qua MỘT helper writeUpstream(_:flush:) giữ guard, để không đường code tương lai nào ghi được mà không qua guard. Đây là thứ tôi yêu cầu ở round 3 và nhận về point-fix thứ ba. — Cost nếu sai: một hàm private nhỏ.

**R35 — Task 6.** Important mới (else-branch nil upstream → phần còn lại của request bị phân loại lại thành "đang connect" và được đệm im lặng; nếu vượt cap thì abortForUpstreamBufferOverflow ghi một HTTP response THỨ HAI không ai yêu cầu lên connection đã nhận response hoàn chỉnh) — ĐÚNG. Quyết: set isUpstreamAborted = true trong else-branch.

**R36 — Task 6.** Important mới (test upstreamDeathMidRequestFailsCleanly KHÔNG chạy qua guard nào cả — origin đóng ở .head nên proxy đóng client trước khi body được gửi 300ms sau; và assertion failedCount==1 là tautology vì collector break ở .failed đầu tiên) — ĐÚNG và nghiêm trọng: thay đổi trung tâm của round 3 vẫn chưa có test. Delay 300ms là padding chứ không phải đồng bộ hoá, nhưng hỏng theo hướng đỏ-flaky chứ không xanh-giả. Quyết: thay bằng test EmbeddedChannel với stub upstream mà test tự lật isActive — deterministic thật, và làm cho assertion failedCount có nghĩa.

**R37 — Task 7.** Important #1 (GuardedPeer.close() vứt im lặng byte chưa flush; close0 gọi cancelWritesOnClose và mọi byte trong pendingWrites bị bỏ với promise nil) — ĐÚNG và nghiêm trọng. Tới được bất cứ khi nào origin nhanh hơn client, tức MỌI download lớn qua host bypass: origin xong và đóng, đuôi transfer không bao giờ tới client, transaction .tunnelled không thể hiện gì bất thường. Đây đúng lớp bug mà cả bài tập GuardedPeer sinh ra để diệt, và report chỉ mô tả nó như "thiếu backpressure" chứ không nhận ra là truncation. Quyết: fix bằng closeAfterPendingWrites() trong chính shape hiện có. — Cost nếu sai: một hàm nhỏ.

**R38 — Task 7.** Important #2 (KHÔNG test nào chạy qua nhánh forward byte thừa — đúng đường mà deviation sinh ra để phục vụ, và đúng đường Task 8 thừa hưởng cho ClientHello) — ĐÚNG. Report ngụ ý đã chạm tới nhưng thực tế mọi test đều kết thúc CONNECT đúng ở \r\n\r\n rồi mới gửi tiếp. Quyết: bắt thêm test gửi CONNECT + payload thô trong MỘT writeAndFlush.

**R39 — Task 7.** Important #3 (doc comment của GuardedPeer khẳng định bất biến mà codebase KHÔNG giữ: "no handler holds a raw Channel anymore", trong khi UpstreamHandler.clientChannel còn 7 chỗ ghi không guard) — ĐÚNG. Report trung thực nhưng CODE thì không, mà code mới là thứ tác giả Task 8 đọc. Đây chính xác là khuôn mẫu "bất biến được duy trì bằng một lập luận viết ở một chỗ" đã đẻ ra 4 vòng của Task 6. Quyết: sửa comment cho đúng sự thật, nêu đích danh ngoại lệ còn lại.

**R40 — Task 7.** Important #4 (clientChannel chưa reachable hôm nay nhưng chỉ nhờ lập luận thứ tự; chế độ hỏng là fatalError mức process, và Task 8 sắp thêm NIOSSLServerHandler + HTTP stack thứ hai + UpstreamHandler thứ hai vào cùng channel) — Quyết: bọc GuardedPeer<HTTPServerResponsePart> NGAY BÂY GIỜ. Lập luận chi phí của reviewer thuyết phục: nhỏ bây giờ, lớn sau Task 8. — Cost nếu sai: một lần refactor thừa.

**R41 — Task 7.** Important MỚI (hard close từ handler đối diện chiếm quyền trước closeAfterPendingWrites, ở CẢ HAI chiều) — ĐÚNG. Kịch bản: origin xong download lớn rồi đóng → TunnelRelayHandler xếp graceful close và hoãn đóng client để đuôi kịp chảy; nhưng ConnectTunnelHandler không hề được báo upstream đã chết, nên byte client gửi trong cửa sổ đó làm upstream.write trả false và abandon HARD-CLOSE client, cancelWritesOnClose vứt sạch đuôi. Không hề exotic: HTTP/2 qua host pinned gửi WINDOW_UPDATE/PING suốt quá trình download. Đây lại đúng hình dạng finding 1, lần này trên đường THÀNH CÔNG. Quyết: fix cả hai chiều + thêm deadline có chặn cho closeAfterPendingWrites (một thay đổi đóng luôn concern no-timeout). — Cost nếu sai: một tham số deadline.

**R42 — Task 7.** concern no-timeout của implementer — reviewer phán đúng là "cùng một lỗi nhìn từ phía kia", nên gộp vào cùng bản sửa. Rò có chặn theo từng connection chứ không phải vô hạn, nhưng chờ có chặn (10-30s, huỷ khi xong) tốt hơn hẳn cả treo vô hạn lẫn cắt cụt im lặng, và tốn ~5 dòng.

**R43 — Task 7.** DEVIATION ĐÚNG, không revert. Reviewer đưa lý do mạnh hơn lý do implementer tự nêu: trong NIOPosix mọi fireErrorCaught trên stream channel đã kết nối đều bị NIO tự close0(.all) ngay sau đó (shouldCloseOnReadError trả true vô điều kiện cho SocketChannel). Nên chân bị lỗi bị đóng cứng dù handler có yêu cầu hay không — quyết định DUY NHẤT mà errorCaught thật sự đưa ra là làm gì với peer còn sống, và ở đó hard close phá tới cả response đã xếp hàng mà không thêm được tín hiệu gì. Chỉ thị của tôi, áp lên peer, không thể mua được tín hiệu mà nó định mua. Tôi sai, implementer đúng.

**R44 — Task 7.** Important MỚI (deadline 15s TRÙM CẢ giai đoạn drain, nên có thể cắt cụt im lặng một client chậm nhưng khoẻ mạnh — đúng lớp bug cũ, lần này trên một cái ngòi nổ). Deadline được arm lúc teardown và chỉ huỷ bởi closeFuture tức full close, nên nó gộp hai pha vào một ngân sách: (a) drain pendingWrites, hết giờ = phá dữ liệu; (b) chờ FIN của peer sau FIN của ta, hết giờ = không phá gì. Tunnel không có backpressure nên lượng pending là vô hạn về nguyên tắc. Quyết: tách deadline, quan sát promise của close(mode:.output) để phân biệt hai pha. — Cost nếu sai: thêm một promise.

**R45 — Task 7.** lời khai "không test deterministic được" của implementer là SAI như đã phát biểu. Reviewer chỉ ra fireErrorCaught là public và TunnelRelayHandler/GuardedPeer dựng trực tiếp được từ test @testable — TIÊM lỗi thay vì KHIÊU KHÍCH lỗi thì không còn race kernel nào. Quyết: bắt viết test đó. Cảnh báo kèm: EmbeddedChannel.close0 BỎ QUA CloseMode và luôn full close, nên test dựa trên EmbeddedChannel sẽ âm thầm quan sát sai thứ.

**R46 — Task 7.** TunnelRelayHandler không có sink nên lỗi upstream không sinh event nào — transaction ở nguyên .tunnelled. Reset tình cờ thì đúng, nhưng reset thật giữa download thì client nhận FIN gọn gàng VÀ bản ghi báo tunnel sạch. Đó là công cụ nói dối. Quyết: cấp sink cho nó, để quy tắc thành đủ: chân lỗi đóng cứng, chân sống đóng mềm, thất bại ĐƯỢC GHI.

**R47 — Task 7.** Important tiềm ẩn (GuardedPeer.write trả TRUE cho channel đã nửa-đóng, trong khi NIO VỨT byte) — ĐÚNG và phải sửa NGAY. Cơ chế: close0(mode:.output) không đụng lifecycleManager nên isActive vẫn true; sau khi outputShutdown = true thì bufferPendingWrite fail vào promise, mà write luôn truyền promise: nil. Nên tín hiệu từ chối — toàn bộ lý do tồn tại của Bool không-discardable — báo THÀNH CÔNG. Đúng lớp bug cũ, qua đúng cái cửa close() mà doc comment của chính file này cảnh báo. Hiện chưa reachable, nhưng chỉ nhờ lập luận thứ tự bắc qua hai handler ở hai pipeline — đúng loại lập luận mà chính file này ghi là đã hỏng ba lần. Task 8 sắp thêm writer vào CẢ HAI channel đó. Quyết: làm structural TRƯỚC khi Task 8 đáp xuống; rẻ hơn nhiều so với sửa sau khi có thêm writer.

**R48 — Task 7.** mục "assertInEventLoop KHÔNG PHẢI precondition" — reviewer bác claim của implementer: mọi entry point của SynchronousOperations dùng assertInEventLoop (debugOnly), không phải preconditionInEventLoop. Nên "63 test xanh ở debug" chứng minh được các site hôm nay đúng loop, nhưng KHÔNG chứng minh gì cho release, nơi construction sai loop sẽ âm thầm sửa linked list của pipeline và race trên một Bool không đồng bộ. Nguy hiểm hơn: hai site dựng peer cho channel CLIENT từ bên trong channelInitializer của channel UPSTREAM, chỉ đúng loop nhờ bootstrap dùng group: context.eventLoop — đúng thứ Task 8 có thể đổi. Quyết: KHÔNG mở round 5 cho 2 dòng; gộp thành bước bắt buộc ĐẦU TIÊN của Task 8, vì đó là file Task 8 sẽ sửa và bản sửa tồn tại chính là để Task 8 an toàn.

**R49 — Task 8.** Important #1 (closeAfterPendingWrites:305 vẫn assertInEventLoop, mà đó là chỗ DUY NHẤT chủ động ghi cờ chia sẻ; doc vừa viết lại thì khẳng định ngược) — ĐÚNG. Requirement 1 áp cho hai hàm được nêu tên nhưng bỏ sót đúng hàm ghi cờ. Một dòng.

**R50 — Task 8.** Important #2 (lập luận "compiler chặn" của H1 là SAI) — ĐÚNG và tôi đã khen nhầm. Part là PHANTOM parameter: GuardedPeer chỉ lưu Channel, không gì buộc Part khớp kiểu outbound của channel đó. Và codebase ĐÃ CÓ sẵn khuôn mẫu phá guard: ConnectTunnelHandler:82 viết GuardedPeer<ByteBuffer>(channel:) với type argument tường minh, :241-244 còn ghi rõ chọn <ByteBuffer> CHÍNH LÀ để mở khoá closeAfterPendingWrites. Handler tương lai làm theo khuôn mẫu đó trên channel MitM sẽ biên dịch, chạy, và mở lại H1. Quyết: hoặc doc trung thực, hoặc kiểm tra thật lúc chạy — nhưng KHÔNG được tuyên bố bảo đảm mà kiểu không cung cấp. Doc sai về bất biến là chế độ hỏng tái diễn của dự án này.

**R51 — Task 8.** Important #3 (MitM CONNECT thành công không bao giờ có terminal event → MỌI kết nối HTTPS để lại một transaction kẹt .pending vĩnh viễn) — leo thang đúng như implementer cảnh báo. Trước chỉ chạm host bypass, giờ chạm tất cả. Và việc các GET bên trong hoàn tất đúng làm nó TỆ HƠN chứ không nhẹ đi: danh sách sẽ hiện N dòng GET sạch cộng một dòng kẹt "pending" mỗi kết nối. Đây đúng chữ ký lỗi của dự án — công cụ hiển thị một trạng thái không đúng sự thật. Quyết: sửa NGAY trong Task 8, không đẩy sang task UI. Phát terminal event khi kết nối MitM/tunnel đóng sạch, mang theo đúng "200 Connection Established" mà proxy THẬT SỰ đã gửi — trung thực và dùng lại máy móc sẵn có. Sửa chung cho cả nhánh tunnel của Task 7.

**R52 — Task 8.** TransactionState conflation — SỬA NGAY, không để trôi. Lập luận của reviewer đúng thứ đã đúng suốt dự án: để .tunnelled nằm trong enum vòng đời nghĩa là bất biến "đừng ghi đè .tunnelled" được giữ bởi việc tác giả reducer NHỚ một comment. Đó đúng là khuôn mẫu đã ngốn tám vòng fix. Chuyển sang Transaction.isTunnelled: Bool VÀ XOÁ case — giữ cả hai là hai nguồn sự thật cho cùng một sự việc, đúng cách mọi chuyện bắt đầu. Blast radius nhỏ và nằm trọn trong code Task 8 đã sở hữu: một chỗ dựng + 4 assertion test. Hôm nay chưa nói dối vì chưa có consumer nào; Task 10 là chỗ bug đáp xuống. — Cost nếu sai: một field Bool.

**R53 — Task 8.** lỗ hổng phủ test legOpened/legClosed — xoá một legOpened thì .completed bắn ở chân ĐẦU (đúng bug N3 mà implementer tự bắt) mà cả test e2e lẫn hai unit test đều vẫn xanh. Sửa rẻ: mirror của rejectedBytesAreNotCountedAsRelayed. Quyết: bắt ghim.

**R54 — Task 9.** Important #1 (isInstalled KHÔNG BAO GIỜ trả false với runner mặc định — nó NÉM) — ĐÚNG và nặng nhất. security find-certificate thoát non-zero khi errSecItemNotFound; do shell script biến non-zero thành lỗi AppleScript; runProcess ném. Nên trạng thái "chưa cài" — tức trạng thái MẶC ĐỊNH của mọi máy trước khi setup, đúng thứ Task 11 render lúc khởi động — lại nổi lên dưới dạng lỗi. Và test của brief mã hoá một mô hình runner KHÔNG THỂ xảy ra nên không bắt được.

**R55 — Task 9.** Important #2 (isInstalled dùng chung runner có quyền) — reviewer BÁC lời tôi ngầm chấp nhận "giới hạn kiến trúc": thêm một tham số có mặc định thứ hai vẫn giữ nguyên chữ ký bắt buộc, mọi test hiện có vẫn biên dịch, tốn ~10 dòng. Cộng với #1 thì isInstalled hôm nay hỏi mật khẩu RỒI NÉM — tệ cả hai đầu.

**R56 — Task 9.** Important #5 (isInstalled chỉ khớp common name nên CA sinh lại báo là ĐÃ CÀI) — ĐÚNG và đây là chế độ hỏng kiểu công-cụ-nói-dối. Người dùng xoá thư mục ca/, loadOrCreate sinh CA MỚI cùng CN, cert cũ vẫn nằm trong keychain → Task 11 hiện "đã tin cậy" → mọi HTTPS hỏng với lỗi TLS mù mờ. Cũng không phân biệt được "có mặt" với "được tin làm root".

**R57 — Task 9.** Important #3 (không có LocalizedError; status luôn = 1 vì đó là exit code của osascript chứ không phải của lệnh) và #4 (runProcess chặn một thread cooperative suốt thời gian hộp thoại mật khẩu, vô hạn nếu người dùng bỏ đi) — cả hai ĐÚNG, cả hai plan-mandated.

**R58 — Task 10.** Important (bản vá cancellation của consume dựa trên một lời khai SAI, và lời khai sai đó giờ nằm vĩnh viễn trong doc comment) — ĐÚNG. Reviewer TỰ TEST trên đúng toolchain 6.3.3: một Task chạy `for await` trên AsyncStream im lặng, chưa finish, không yield VẪN thoát ngay khi Task bị huỷ — có hay không có kiểm Task.isCancelled bên trong. AsyncStream.next() vốn đã cancellation-aware. Nên phép kiểm được thêm vào là VÔ TÁC DỤNG đúng trong kịch bản nó sinh ra để sửa, và implementer khẳng định "tôi đã xác nhận" với mức tự tin nó chưa kiếm được. Code vô hại nhưng lý do thì sai. Quyết: bỏ phép kiểm vô tác dụng và sửa comment — code chết kèm lý do sai còn tệ hơn không có code.

**R59 — Task 12.** Important #1 (CÙNG lỗi "response non-nil che mất .failed thật" vẫn tồn tại cho request THƯỜNG, qua cửa khác) — ĐÚNG và nặng. Đường đi cụ thể reviewer truy được: UpstreamHandler phát .responseHead (header thật, body .none) NGAY khi head của origin tới, TRƯỚC khi body xong; TrafficStore ghi thẳng vào transaction.response; nếu origin chết trước .end (timeout, RST, stream đứt — chuyện thường) thì failAllPending phát .failed, mà nhánh .failed chỉ set state chứ không đụng response. Kết quả: response != nil VÀ state == .failed cùng lúc. InspectorView kiểm response != nil TRƯỚC state == .failed nên hiện ra một response trông bình thường, KHÔNG có dấu hiệu nào là đã hỏng — trong khi StatusCell cùng dòng đó lại báo đúng "thất bại". Không test nào phủ chuỗi này. Quyết: sửa thứ tự kiểm.

**R60 — Task 12.** Important #2 (logic quyết định của responseTab nằm trong body, không test được — trái ràng buộc toàn cục đã nêu rõ, trong khi StatusPresentation của Task 11 là tiền lệ nằm ngay trong file mà diff này sửa) — ĐÚNG, và Important #1 chính là minh chứng: thứ tự kiểm sai một chỗ mà không test nào bắt được. Quyết: tách ra kiểu Equatable tính từ (isTunnelled, state, response), test như JSONNode.

---

## Nợ kỹ thuật còn lại (9 nhóm)

Đã được final review phân loại: 6 mục sửa trước merge (đã sửa trong commit `48fe7a7`), 9 mang theo làm sau, 9 bỏ vì đã tự giải quyết.

- Task 1: minor (deferred): cảnh báo SwiftPM "Source files for target TrafficModelTests/ProxyCoreTests should be located under Tests/..." — Task 2 và Task 5 sẽ tạo hai thư mục đó, tự hết.
- Task 1: minor (deferred): HandshakeCompletionHandler trong test không fail promise ở errorCaught — nếu tương lai handshake vỡ thì test treo vô hạn thay vì fail rõ ràng. Một dòng. Đưa vào danh sách cho final review triage.
- Task 3: minor (deferred): defaultDirectory index [0] không guard; 0o700 có lan sang thư mục trung gian không (chưa test, tác động thấp vì file khoá vẫn 0600); test temp dir không dọn; certificateDER()/privateKey chưa có test riêng.
- Task 5: minor (deferred): sanitize chỉ đọc dòng Connection ĐẦU TIÊN (headers.first(name:)). Nhiều dòng Connection riêng biệt là hợp lệ theo RFC dù hiếm; tên hop-by-hop chỉ liệt kê ở dòng thứ hai sẽ lọt. Sửa bằng headers[name:] gộp hết rồi mới split. Đưa vào danh sách final review triage.
- Task 6: minor (deferred): cảnh báo deprecation origin.close().wait() trong async test; owner xoá file body tạm (Task 10 có deleteSpilledBodies); state thừa trên nhánh bad-request; tách HTTPProxyHandler 339 dòng thành đơn vị nhỏ hơn trước khi Task 8 thêm MitM vào cùng file.
- Task 6: minor (deferred): .requestBody bị bỏ khi response xong trước lúc client upload xong; pipelined host switch để lại transaction .started không bao giờ có terminal event; client ngắt giữa connect cũng để lại .started vĩnh viễn (→ brief Task 7); respond() có 3 bản gần giống nhau.
- Task 6: minor (deferred): writeUpstream nil-path trả false mà không abandon (unreachable hôm nay, nhưng CHỈ nhờ đúng loại lập luận thứ tự mà round này sinh ra để thôi phụ thuộc — 1 dòng); writeUpstream là @discardableResult trong khi wrapper.write cố ý không.
- Task 8: minor (deferred): call site catch trong MITMUpgradeHandler.install chưa được test ghim; đọc RecordingSink ngoài event loop trong một test mới.
- Task 11: minor (deferred): stop() hai lần liên tiếp có thể gọi shutdown() đồng thời (vô hại — double finish() là no-op, shutdownGracefully thứ hai bị try? nuốt); TOCTOU của start(); toolbar tràn "more items"; không có test render SwiftUI thật.

---

## Chưa đóng, ship kèm ruling

1. **Hang HTTP/1.0 close-framed** — xác nhận có từ trước bản fix, được đặt tên trong code như follow-up chứ không tuyên bố thành bất biến.
2. **Cột Size trộn đơn vị** — nghĩa là "byte body response" trên dòng đã giải mã, và "byte thô hai chiều" trên dòng tunnel. Được tooltip và badge công bố. Nên gộp lại khi làm cột sortable.
3. **Thiếu test e2e cho response chunked** sau khi strip Transfer-Encoding. An toàn đã được xác minh độc lập trên nguồn NIO vendored — nhưng bằng ĐỌC, không bằng test, tức dưới chuẩn thường của nhánh này.
4. **Doc comment `TrafficStore.swift:91`** ghi "bốn case" trong khi giờ có năm.

## PRE-RELEASE BLOCKER (không chặn merge)

**TOCTOU của trust-store installer.** `install()` bảo root tin một file mà user ghi được, có cửa sổ TOCTOU và
không kiểm nội dung. Nó biến "code chạy quyền user" thành "code cài được trust anchor toàn hệ thống" trên lưng
đúng một lần bấm admin — và hộp thoại xác thực hiện tên *osascript*, không phải tên certificate, nên người dùng
không phát hiện được sự thay thế. Không chặn merge vì spec §10 đã hoãn signing/sandbox, nhưng **phải giải quyết
trước khi phát hành**. Protocol `TrustStoreInstaller` tồn tại sẵn để thay bằng privileged helper.


---

## Cập nhật 2026-09-13 — PRE-RELEASE BLOCKER ĐÃ ĐÓNG

Blocker ở trên (TOCTOU của trust-store installer) **không còn tồn tại**, và nó
được đóng bằng cách xoá đi chứ không phải vá thêm.

**Triệu chứng phát hiện ra vấn đề:** trên máy Mac thứ hai, nút "Cài Root CA" báo
`SecTrustSettingsSetTrustSettings: The authorization was denied since no user
interaction was possible.`

**Nguyên nhân gốc — lỗi thiết kế trong spec §6.3 của tôi.** `security
add-trusted-cert` làm hai việc: nhập cert vào keychain, rồi gọi
`SecTrustSettingsSetTrustSettings` để đánh dấu được tin. Việc thứ hai cần một
authorization mà `securityd` hỏi bằng hộp thoại **trong phiên GUI của người
dùng**. Một tiến trình root sinh ra từ `osascript do shell script with
administrator privileges` không có kết nối tới phiên đó.

Nên đường admin **chưa bao giờ chạy được từ app GUI**, ở bất kỳ máy nào. Nó chỉ
chạy khi gõ `sudo` trong Terminal. Trên máy đầu tiên nó "gần như chạy": cert vào
được System keychain (nên `find-certificate` thấy), nhưng không bao giờ được tin
(nên `verify-cert` trả `CSSMERR_TP_NOT_TRUSTED`). Chính bản sửa ở Task 9 — đổi
`isInstalled` từ `find-certificate` sang `verify-cert` — là thứ khiến app nói
đúng sự thật thay vì báo "đã cài".

**Bản sửa:** bỏ cờ `-d`, cài vào **user domain** (mặc định của `security`).
`securityd` hiện hộp thoại bình thường trong phiên người dùng, hỏi mật khẩu đăng
nhập. Safari, Chrome, curl của tài khoản đó đều tin CA.

**Hệ quả về bảo mật.** Toàn bộ cỗ máy chạy-dưới-root tồn tại chỉ để ghi vào
System keychain. Bỏ yêu cầu đó thì xoá luôn được: `osascript`, script AppleScript
cố định, hai tầng quoting, `parseExitStatus`, và cửa sổ TOCTOU giữa lúc
`loadOrCreate` trả về và lúc root đọc file. `TrustStoreInstaller.swift` giảm từ
256 xuống 177 dòng, và **không còn đường code nào chạy dưới quyền root**.

**Đánh đổi, ghi rõ:** trust theo từng tài khoản thay vì toàn máy. Với một công cụ
debug chạy trên tài khoản của chính người dùng thì phạm vi hẹp hơn là đúng hơn.
Ai cần toàn máy thì tài liệu trong dmg ghi lệnh `sudo` chạy trong Terminal — nơi
nó vốn chạy được.

**Bài học lặp lại lần nữa:** cách viết cũ được cả một vòng security review đọc kỹ
và khen là "well built" — quoting đúng, guard đúng, không chèn lệnh được. Nó
đúng về mọi mặt trừ một: **nó không chạy được**. Không vòng review nào bắt được,
vì không ai bấm nút thật. Chỉ có người dùng trên máy thứ hai bấm mới lộ ra.
