# KVRouterKit 3.0 — Refactor & Bugfix Plan (v2, clean break)

Mục tiêu: SDK support được Clean Architecture / MVVM và unit test, làm chuẩn ngay từ đầu.

**Không giữ tương thích 2.x.** `KVAppRoute`, `appFeatureViewBuilder`, `deepLinkViewBuilder`
bị xoá hẳn. Không shim, không deprecation layer, không migration guide.

Hệ quả về cách làm: mất lưới an toàn "109 tests luôn xanh". Bù lại bằng cách **viết test
cho hành vi trước, port implementation sau** ở mỗi phase — test mô tả hành vi mong muốn
của 3.0, không phải hành vi của 2.0.

---

## Phạm vi 3.0

**Router chỉ quản lý navigation stack (push / pop).** Modal dùng `.sheet` và
`.fullScreenCover` native của SwiftUI, app tự quản.

Lý do: sheet vốn mang tính cục bộ — present từ một view cụ thể, đóng bằng
`@Environment(\.dismiss)`, và `.sheet(isPresented:)` đã đủ khai báo. Không có sự vênh nào
với framework để SDK phải bù. Giá trị thật của router nằm ở chỗ khác: điều khiển stack
theo kiểu mệnh lệnh trên `NavigationStack` cộng custom transition — đúng chỗ SwiftUI khó chịu.

Xoá khỏi SDK (~330 dòng, 152 chỗ tham chiếu trên 5 file):

- `KVSheetRoute`, `KVFullCoverRoute`
- `router.sheet` / `router.fullCover` và toàn bộ observation cho chúng
- `present`, `presentSheet`, `presentFull`, `presentFullCover`, `dismissSheet`,
  `dismissSheet(afterDismiss:)`, `dismissFull`, `dismissSheetThenPresentFull`
- `customSheetBuilders`, `customFullCoverBuilders`, `buildSheet`, `buildFullCover`
- `sheetDidDismiss`, `fullCoverDidDismiss`, `awaitSheetDismissal`, `sheetDismissWaiters`
- `KVRouteMiddleware.willDismiss` và `applyDismissMiddlewares`
- `.sheet` / `.fullScreenCover` cùng binding của chúng trong `KVRouterHost`

**Ba bug biến mất theo, không cần fix:**

- **BUG-1** (rò builder sheet khi vuốt xuống đóng) — không còn builder để rò. Giả thuyết
  chưa chứng minh này giờ thành vô nghĩa, khỏi cần test tái hiện.
- Continuation leak trong `awaitSheetDismissal` (đã vá) — code đi luôn.
- Toàn bộ vũ đạo timeout 700ms của `dismissSheetThenPresentFull` — đoạn nhạy cảm thời gian
  nhất trong package.

**Không hỏng gì:** coordinator vốn chỉ xử lý `.push`/`.pop`, sheet chưa bao giờ đi qua nó.
Check `presentedViewController == nil` ở `KVInteractiveTransitionController.swift:187` giữ
nguyên — `.sheet` native vẫn tạo `presentedViewController` nên gesture vuốt-back vẫn tự từ
chối khi có modal đang mở.

**Khoảng trống 1 — zoom transition vào modal.** `kvTransitionSource(id:)` là `public`, nhưng
namespace nó dùng (`EnvironmentValues.kvTransitionNamespace`, `KVRouterEnvironment.swift:34`)
là **internal**, và `.navigationTransition(.zoom(sourceID:in:))` hiện chỉ được áp trong
`KVRouterDestinationContent` — tức chỉ cho màn hình push. App tự present `.sheet` thì không
lấy được namespace, không nối được source với destination.

→ Mở namespace ra qua một modifier tường minh:

```swift
@available(iOS 18.0, *)
public extension View {
    /// Đánh dấu nội dung modal là đích zoom của `kvTransitionSource(id:)`.
    func kvZoomDestination<ID: Hashable>(sourceID: ID) -> some View
}
```

Sheet content thừa kế environment của view present nó nên namespace lan tới được.
**Chỉ iOS 18+** — zoom cho modal dựa hoàn toàn vào API native; trên iOS 16/17 muốn zoom vào
sheet phải tự viết `UIViewControllerTransitioningDelegate` cho presentation, cơ chế khác hẳn
animator hiện tại (vốn cắm vào `UINavigationControllerDelegate`). Không làm, iOS 16/17 rơi
về sheet thường.
**Chưa verify:** `.navigationTransition(.zoom:)` áp lên content của `.sheet` có chạy không.
Phải thử trên simulator trước khi cam kết — nếu Apple chỉ hỗ trợ cho `NavigationStack` push
thì zoom-to-modal nằm ngoài tầm 3.0.

**Khoảng trống 2 — deep link mở modal (`myapp://settings` bật settings
dạng sheet). Router sở hữu sheet thì việc này dễ; giờ deep link phải với tới state của đúng
view đó. Hai lối ra: (a) deep link luôn `push`, không present — đơn giản nhất, và hợp lý vì
nội dung đến từ URL thường xứng đáng có chỗ trong stack; (b) app tự giữ một app-state object
cho modal. Tôi nghiêng về (a), nhưng nếu app bạn có màn hình bắt buộc mở dạng modal từ URL
thì nói để tính lại.

---

## Những chỗ v2 sửa lại so với v1

| v1 nói | Thực tế | v2 |
|---|---|---|
| Tách `KVAppRouter` vào `KVRouterCore` | Coordinator + host gọi **15 member internal** của router (`interactivePopRequest`, `prepareInteractivePop`, `commitInteractivePop`, `navigationEntries`, `transitionOverride`, `sheetDidDismiss`, `buildView`…) cộng 4 kiểu internal. Tách ra là phải `@_spi` hoặc `public` gần hết phần ruột. | Core **chỉ chứa port + route model**, implementation ở lại Kit. Bề mặt xuyên module còn 3 protocol. |
| `swift test` chạy ~57 test, CI nhanh | App của bạn là iOS → test app vẫn chạy simulator dù có Core hay không. Và với Core tối giản thì trong đó gần như không còn logic để test. | Bỏ luôn `.macOS` platform và `#if canImport(UIKit)`. Giá trị thật là **mock được**, không phải `swift test`. |
| `KVRouting.push(_:transition:)` | ViewModel chọn animation là vi phạm layering. | Port không mang transition. Nhờ đó **Core sạch tuyệt đối: chỉ Foundation**, không SwiftUI không UIKit. |
| BUG-2/4/5 fix bằng patch | Clean break cho phép thiết kế để lớp bug đó không tồn tại. | Chuyển thành yêu cầu thiết kế của state machine mới. |

---

## Phần A — Kiến trúc đích

```
Sources/
  KVRouterCore/     port + route model. CHỈ Foundation.        (~200 dòng)
  KVRouterKit/      KVAppRouter, host, registry, transitions, swizzling.
  KVRouterTesting/  KVRouterSpy + fakes.  (→ Core)
```

Chiều phụ thuộc: `Kit → Core`, `Testing → Core`. Core không phụ thuộc gì.

Đây là toàn bộ điểm mấu chốt: **ViewModel của app chỉ import `KVRouterCore`** — một module
~200 dòng không kéo theo SwiftUI, UIKit, Introspect hay swizzling. Test ViewModel dựng
`KVRouterSpy` đồng bộ, không cần `KVAppRouter` thật (vốn `@MainActor`, có hàng đợi async,
kéo cả bộ máy SwiftUI).

Không tách `KVRouterTransitions` riêng ở 3.0: coordinator và router bám nhau quá chặt
(15 member ở trên), tách ra chỉ đổi coupling nội bộ thành `@_spi` công khai. Việc gỡ
swizzling khỏi đường mặc định để sau, khi đã tháo được `coordinator` khỏi `@StateObject`
của host.

### Core — route model

```swift
public protocol KVRoute: Hashable, Sendable {}

public struct AnyKVRoute: Hashable, Sendable {
    public let base: any KVRoute
}

public protocol KVRestorableRoute: KVRoute, Codable {
    static var restorationID: String { get }   // mặc định = String(reflecting: Self.self)
}
```

`KVAppRoute` biến mất. Ba case cũ đi về đâu:

- `appFeature(String)` → app tự khai enum route của mình, type-safe thật.
- `deepLink(String)` → parser trả `[any KVRoute]` (Phase 5).
- `customView(UUID)` → `KVDynamicViewRoute` (internal), conform `KVRoute` như mọi route khác:

```swift
struct KVDynamicViewRoute: KVRoute {
    let id: UUID
    let tag: String?
    let typeName: String
}
```

Lợi ích phụ đáng kể: `route(_:matchesTag:)` và `route(_:matchesViewType:)` hiện đang
special-case enum (`.customView` tra registry, `.appFeature` so id, `.deepLink` luôn false)
— giờ thành một phép so sánh trên chính route. Mất hẳn một lớp phân nhánh.

### Core — port

```swift
@MainActor public protocol KVRouting: AnyObject {
    func push(_ route: any KVRoute)
    func pop()
    func pop(count: Int)
    func popToRoot()
    func popTo(_ route: any KVRoute)
    func popTo(tag: String)
}
```

Chỉ có lệnh stack — không state, không modal, không `transition:`, không `pushView`.
Transition và `pushView` là quyết định của tầng View nên thuộc `KVViewRouting`; modal thì
SDK không đụng tới.

### Kit — port mở rộng cho tầng View

```swift
@MainActor public protocol KVViewRouting: KVRouting {
    func push(_ route: any KVRoute, transition: KVNavigationTransition)
    func pushView<V: View>(tag: String?, _ build: @escaping () -> V)
    func pushView<V: View>(tag: String?, transition: KVNavigationTransition, _ build: @escaping () -> V)
    func popTo<V: View>(_ viewType: V.Type)
    func replaceTop(with route: any KVRoute)
}

extension KVAppRouter: KVViewRouting {}
```

**`pushView { }` giữ nguyên 100% khả năng.** Nó chỉ không lọt vào port hẹp mà ViewModel nhận.
Team nào muốn VM push view động thì inject `any KVViewRouting` — vẫn mock được, chỉ lỏng hơn
về layering. SDK không ép.

### Kit — registry

```swift
KVRouterHost(router: router) { HomeView() }
    .kvRoutes { r in
        r.register(ShopRoute.self) { route in
            switch route {
            case .productDetail(let id): ProductDetailView(vm: .init(id: id, router: router))
            case .cart:                  CartView()
            }
        }
    }
```

Route ở feature module không biết SwiftUI tồn tại; ánh xạ route → view nằm ở composition root.
Đây chính là ranh giới Clean Architecture cần.

---

## Phần B — Bug fixes

Clean break đổi cách xử lý: 3 bug không còn là "vá" mà là **ràng buộc thiết kế** của state
machine mới. Số còn lại nằm ở tầng UIKit gần như không đổi nên vẫn là fix thẳng.

### Thiết kế để không tồn tại

**BUG-2 — `isRouterControlledPop` kẹt `true`.** `commitInteractivePop` thoát sớm khi top stack
đã đổi mà không reset cờ → lần swipe-back kế tiếp **bỏ qua middleware `willPop`**. Với
middleware kiểu "cảnh báo chưa lưu" thì đó là mất dữ liệu im lặng.
→ 3.0 không dùng cờ `Bool`. Dùng `Set<UUID>` chứa id entry mà router chủ động gỡ. Một cờ
toàn cục không thể mô tả đúng nhiều đường pop chồng nhau — đó là lỗi mô hình, không phải lỗi code.

**BUG-4 — `handlePathChange` bắn n Task rời rạc** (`KVAppRouter.swift:249`), nằm **ngoài**
hàng đợi FIFO mà cả file còn lại xây rất kỹ để giữ. Middleware của system pop có thể xen giữa
hai operation lập trình.
→ 3.0: mọi phản ứng với thay đổi path đi qua đúng một hàng đợi. Không có đường tắt.

**BUG-5 — middleware treo khoá router vĩnh viễn** (`enqueue`, `KVAppRouter.swift:208`).
`performNavigation` có watchdog, `applyMiddlewares` không. Một middleware `await` không bao
giờ return sẽ chặn mọi điều hướng sau đó, không log, không đường phục hồi.
→ 3.0: timeout là thuộc tính của hàng đợi, áp cho mọi stage. Hết giờ → huỷ operation +
`assertionFailure` trong DEBUG.

### Fix thẳng

*(BUG-1 — rò builder sheet/fullCover khi vuốt xuống đóng — đã bị xoá sổ bởi quyết định
thu hẹp phạm vi, xem mục "Phạm vi 3.0".)*

**BUG-3 (P1) — coordinator ôm router cũ.** `KVRouterHost.swift:55`. `coordinator.router = router`
chỉ chạy trong `onAppear`; app đổi router instance (logout → router mới) mà host không teardown
thì coordinator trỏ vào router đã chết. → `.task(id: ObjectIdentifier(router))`.

**BUG-6 (P2) — Task rác.** `KVTransitionCoordinator.swift:452`, mỗi push/pop `.system`/`.nativeZoom`
tạo Task ngủ 1.25s không cancel. → giữ handle và `cancel()`, đúng pattern `scheduleWatchdog`.

**BUG-7 (P2) — TabView làm rụng transition driver.** `KVRouterHost.swift:61`, chuyển tab →
`onDisappear` → `detach()`. → ref-count attach/detach.

**BUG-9 (P2) — `replaceTop(transition:)` không animate.** `KVTransitionOperation.replace`
không được tạo ở bất cứ đâu; `replaceTop` nhét transition vào `transitionOverrides` nhưng
không gọi `performNavigation`, nên replace không animate và transition chỉ có hiệu lực lúc
entry bị pop về sau. API nhận tham số mà không làm điều tên nó hứa. Chi tiết và hai phương án
ở [api-inventory-3.0.md §5.1](api-inventory-3.0.md).

**BUG-8 (P3) — router mặc định nuốt navigation im lặng.** `KVRouterEnvironment.swift:20`.
Quên bọc `KVRouterHost` thì push vào một router global vô hình: không crash, không log, không
gì xảy ra. → `KVNullRouter` `assertionFailure` trong DEBUG, no-op ở release.

### Đã fix

| | |
|---|---|
| ✅ | `@ObservedObject` ở destination content → `let`; hết re-render toàn stack mỗi khi bất kỳ property nào của router đổi |
| ✅ | Xoá dead code `cleanupTopBuilderIfNeeded()` / `cleanupBuilders(from:)` |
| ✅ | Đọc `_navigationEntries` nội bộ thay vì `path` (bỏ cấp phát mảng mỗi lần đọc) |
| ✅ | Dual-observation gọn lại bằng strategy pattern (xem mục Observation) |
| ⊘ | Continuation leak `awaitSheetDismissal` — đã vá, nhưng code bị xoá ở Phase 2 |

---

## Phần C — Phase

### Phase 1 — Core + Testing
Dựng `KVRouterCore` (`KVRoute`, `AnyKVRoute`, `KVRestorableRoute`, `KVRouting`,
`KVRouteMiddleware`) và `KVRouterTesting` (`KVRouterSpy`, `await settle()`).
`Package.swift` 3 target.

Kiểm kê đầy đủ bề mặt public → đích của từng API: **[api-inventory-3.0.md](api-inventory-3.0.md)**
(sketch ở Phần A chỉ là phác thảo, bảng kiểm kê mới là nguồn đúng — nó sửa lại chỗ Phần A xếp
`popTo(tag:)` vào `KVRouting`).

Vướng thứ tự cần xử lý: nếu Kit hoàn toàn không đổi ở phase này thì `KVAppRouter` chưa
conform `KVRouting`, nên spy và router thật chưa thay thế được cho nhau — ViewModel viết ở
Phase 1 phải đợi tới Phase 3 mới cắm vào app thật được. Cách gỡ: Phase 1 cho `KVAppRoute`
conform `KVRoute` **nội bộ, tạm thời** (không public, không phải shim tương thích) để
`KVAppRouter: KVRouting` chạy được ngay; Phase 3 xoá `KVAppRoute` thì conformance đi theo.
Nhờ vậy mỗi phase đều để lại một trạng thái dùng được đầu-cuối.

**DoD:** ViewModel nhận `any KVRouting`, test bằng spy, và cắm được vào `KVAppRouter` thật.

### Phase 2 — Cắt modal
Xoá toàn bộ lớp sheet / fullCover khỏi router và host (danh sách ở mục "Phạm vi 3.0").
Làm **trước** Phase 3 vì nó cắt đi ~330 dòng: mọi việc sau đó thao tác trên codebase nhỏ hơn,
và 3 bug biến mất nên không tốn công port test cho chúng.
Example app có 8 chỗ gọi modal phải chuyển sang `.sheet` / `.fullScreenCover` native:
`ContentView.swift:44,47,50,53` và `ExampleScreens.swift:218,220-222,240`. Chỗ
`ExampleScreens.swift:220` là ví dụ sheet → cover (`presentFullCover` tự đóng sheet rồi chờ)
— đây là case duy nhất app phải tự lo, và cũng là lý do nên giữ nó trong example như một
recipe có tài liệu.
**DoD:** example app chuyển sang modal native, hành vi không đổi dưới góc nhìn người dùng.

### Phase 3 — Thay route model trong Kit
Xoá `KVAppRoute`. `KVAppRouter` chuyển sang `AnyKVRoute` + `KVDynamicViewRoute`.
`KVAppRouter: KVViewRouting`. Registry + `.kvRoutes { }`. Xoá `appFeatureViewBuilder` /
`deepLinkViewBuilder`. State restoration qua `KVRestorableRoute`.
Đây là phase nặng nhất — chạm gần như mọi file và viết lại phần lớn test còn lại.
**DoD:** push/pop/popTo/restore chạy với route tuỳ biến; example app dùng typed route.

### Phase 4 — State machine + bug
Viết lại phần điều phối path: `Set<UUID>` thay cờ Bool (BUG-2), gộp `handlePathChange` vào
hàng đợi (BUG-4), timeout cho mọi stage (BUG-5). Kèm BUG-3, 6, 7, 8.
**DoD:** mỗi bug có test tái hiện đỏ trước, xanh sau.

### Phase 5 — Codec cho state restoration
**Deep link đã gộp vào Phase 3, không tách được:** xoá `deepLink(String)` làm `handle(url:)`
mất lý do tồn tại, để lại thì có trạng thái trung gian hỏng. Kết quả còn tốt hơn dự tính —
không cần thêm protocol `KVDeepLinkParser` nào cả: app tự `.onOpenURL` rồi `push`, nên đây
là **xoá API** chứ không phải thêm.

Việc còn lại của phase này là mã hoá stack `[any KVRoute]`: cần codec map `restorationID` về
kiểu cụ thể khi decode. **Đang là regression so với 2.0** (2.0 có `restorePath` vì
`KVAppRoute` là `Codable`); README đã ghi rõ giới hạn tạm thời này.

### Phase 6 — Dọn & release
Chuyển accessor test-only của `KVTransitionEndpoint` (~50 dòng production code mà Sources
không ai gọi) sang test target. CI (`.github/` chưa có). README + CHANGELOG 3.0.0.

**Không migrate 128 test sang Swift Testing — lý do kỹ thuật của plan không đúng.** Plan
giả định các test descriptor lặp cơ học nên `@Test(arguments:)` sẽ gọn lại. Soi thực tế thì
mỗi test assert những con số **khác nhau** đặc thù từng style (offset slide, scale depth, góc
flip); tham số hoá chỉ dồn số vào bảng và làm failure khó đọc hơn. Còn lại chỉ là diagnostic
đẹp hơn — không đáng rewrite 128 test đang xanh.

Thay vào đó: hai framework sống chung trong một target, test **mới** viết bằng Swift Testing.
Bắt đầu bằng `KVRouteRegistry` và `KVDynamicViewRoute` — code mới của Phase 3 mà chưa có test
nào chạm tới.

### Để đợt sau
- **Navigation results** — `await router.push(_:expecting:)`. Ergonomics lớn cho MVVM
  (picker, confirm, login) nhưng thêm continuation gắn vòng đời entry.
- **Scoped/child router** — TabView per-tab stack, app module hoá. Gộp BUG-7.
- **Transitions opt-in** — gỡ swizzling khỏi đường mặc định.

---

## Observation — đã chốt: giữ iOS 16

Không nâng min lên iOS 17. Lớp dual-observation đã được gọn lại bằng strategy pattern
(`KVObservationStrategy` / `KVModernObservation` / `KVLegacyObservation`): backend chọn
**một lần lúc init**, nên hot path không còn `if #available` + `as? ObservationRegistrar`
unbox ở mỗi lần đọc property. Chi phí còn ~50 dòng trong một file, không rò ra public API —
không đáng đổi lấy việc mất thiết bị iOS 16.

**Bẫy cần thiết kế để tránh — dual observation không đối xứng:**

```swift
@Environment(\.router) private var router
var body: some View { Text("\(router.path.count)") }
```

iOS 17+ chạy đúng (Observation theo dõi được `path`). iOS 16 **không bao giờ update** —
`@Environment` không observe `ObservableObject` — mà không warning, không crash. Cùng một
đoạn code, sai âm thầm trên OS cũ.

→ 3.0 coi `path` là **chi tiết nội bộ của host** (sau Phase 2 thì đó cũng là state observable
duy nhất còn lại). View của app chỉ gửi lệnh (`router.push(...)`), không đọc state. Điều này
khớp sẵn với port `KVRouting` ở Phase 1 — chỉ có lệnh, không có state. Ai thật sự cần quan sát
stack thì cấp API riêng, tường minh, hành xử giống nhau trên cả hai OS.

## Rủi ro

**Cao — Phase 3 không có lưới an toàn.** Clean break nghĩa là phần lớn test hiện tại không
dùng lại được nguyên trạng, mà Phase 3 lại chạm gần như mọi file. Giảm thiểu: làm Phase 1
(Testing target) *trước*, và trong Phase 3 viết test hành vi 3.0 trước khi port implementation.

**Trung bình — zoom-to-modal chưa được chứng minh khả thi.** Xem "Khoảng trống 1". Verify
bằng simulator trước, không cam kết trong scope cho tới khi có kết quả.

**Thấp — kiểm kê API chưa đầy đủ.** Các sketch `KVRouting` / `KVViewRouting` ở trên mới là
phác thảo, chưa phải kiểm kê. API public hiện có còn `setPath`, `restorePath`, `replaceTop`,
`replaceTopWithView`, `popTo(where:)`, `popTo(_:)` cho view type. Việc đầu tiên của Phase 1
là liệt kê đủ bề mặt public hiện tại rồi quyết từng cái: vào `KVRouting`, vào `KVViewRouting`,
hay bỏ.
