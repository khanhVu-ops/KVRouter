# Kiểm kê API public → 3.0

Việc đầu tiên của Phase 1. Mỗi API public hiện tại được quyết một trong bốn đích:

| Ký hiệu | Nghĩa |
|---|---|
| **Core** | `KVRouting` trong `KVRouterCore` — lệnh stack thuần, ViewModel dùng được, không SwiftUI |
| **View** | `KVViewRouting` trong `KVRouterKit` — cần `View` hoặc `KVNavigationTransition` |
| **Xoá** | không còn ở 3.0 |
| **Nội bộ** | vẫn tồn tại nhưng thôi public |

---

## 1. Lệnh navigation stack

| API hiện tại | Đích | Ghi chú |
|---|---|---|
| `push(_ route:)` | **Core** | signature đổi `KVAppRoute` → `any KVRoute` |
| `push(_ route:, transition:)` | **View** | |
| `pushView(tag:_:)` | **View** | |
| `pushView(tag:transition:_:)` | **View** | |
| `pushView(_ view:, tag:)` | **View** | |
| `pushView(_ view:, tag:, transition:)` | **View** | |
| `replaceTop(with:)` | **Core** | |
| `replaceTop(with:, transition:)` | **View** | ⚠️ xem BUG-9 |
| `replaceTopWithView(tag:_:)` | **View** | |
| `replaceTopWithView(tag:transition:_:)` | **View** | |
| `setPath(_:)` | **Core** | |
| `restorePath(_:)` | **Xoá** | thay bằng `KVPathCodec` + `setPath` — xem §5 |
| `pop()` | **Core** | |
| `pop(count:)` | **Core** | |
| `popToRoot()` | **Core** | |
| `popTo(_ route:)` | **Core** | |
| `popTo(where:)` | **Core** | predicate thành `(any KVRoute) -> Bool`, caller phải downcast |
| `popTo(tag:)` | **View** | **plan ghi sai là Core** — xem §5 |
| `popTo(_ viewType:)` | **View** | |
| `path` (get/set) | **Nội bộ** | thay bằng `stackDepth` / `topRoute` — xem §5 |
| `handle(url:)` | **Xoá** | sang `KVDeepLinkParser` (Phase 5) |
| `appFeatureViewBuilder` | **Xoá** | registry thay thế |
| `deepLinkViewBuilder` | **Xoá** | registry thay thế |
| `init(middlewares:)` | **View** | `KVAppRouter` là kiểu cụ thể, sống ở Kit |

## 2. Modal — xoá toàn bộ (Phase 2)

`KVSheetRoute`, `KVFullCoverRoute` (+ `id`), `sheet`, `fullCover`, `present(_:)`,
`presentSheet` ×2, `dismissSheet` ×2, `presentFull(_:)`, `presentFullCover` ×2,
`dismissFull()`, `dismissSheetThenPresentFull(_:)`, `KVRouteMiddleware.willDismiss`.

## 3. Route model

| Hiện tại | Đích |
|---|---|
| `KVAppRoute` (+ `isRestorable`) | **Xoá** → `KVRoute` / `AnyKVRoute` / `KVRestorableRoute` ở Core |

## 4. Middleware, environment, host, transition

| API | Đích | Ghi chú |
|---|---|---|
| `KVRouteMiddleware.willNavigate` / `.willPop` | **Core** | signature sang `any KVRoute` |
| `KVLoggingMiddleware` | **Core** | |
| `EnvironmentValues.router` | **View** | kiểu đổi thành `any KVViewRouting`; default là `KVNullRouter` `assertionFailure` trong DEBUG (BUG-8) |
| `View.appRouter(_:)` | **View** | |
| `View.kvTransitionSource(id:)` | **View** | thêm `kvZoomDestination(sourceID:)` iOS 18+ |
| `KVRouterHost` | **View** | thêm `.kvRoutes { }` |
| `KVNavigationTransition` + toàn bộ static factory | **View** | giữ nguyên, không đổi |
| `KVTransitionAnimation`, `KVTransitionViewState`, `KVTransitionStage`, `KVPopTransition`, `KVFlip3DAxis` | **View** | giữ nguyên, không đổi |
| `KVTransitionOperation` | **View** | case `.replace` — xem BUG-9 |

Toàn bộ API transition (khoảng 40 declaration) đi qua 3.0 **không đổi một dòng**. Đó là phần
đã chín của SDK; refactor không nên chạm vào.

---

## 5. Bốn quyết định cần chốt

### 5.1 BUG-9 (mới) — `replaceTop(transition:)` không animate

`KVTransitionOperation.replace` **không được tạo ở bất cứ đâu** — chỉ xuất hiện trong hai
nhánh `switch` (`KVTransitionAnimator.swift:221`, `KVTransitionDescriptor.swift:105`) không
bao giờ tới được. `replaceTop(with:transition:)` nhét transition vào `transitionOverrides`
qua `makeEntry` nhưng **không gọi `performNavigation`**, nên thao tác replace không hề được
animate. Transition truyền vào chỉ có hiệu lực lúc entry đó bị *pop* về sau.

API công khai nhận tham số mà không làm điều tên nó hứa.

**✅ Đã chốt: fix cho nó animate thật.** Cho replace đi qua `performNavigation` với
`operation: .replace`. Hai nhánh `switch` kia thành sống, `.replace` có lý do tồn tại, tham
số làm đúng việc. Coordinator phải nới `guard request.operation == .push || .pop` để nhận
`.replace`. Làm ở Phase 4 cùng các bug khác.

### 5.2 `popTo(tag:)` thuộc Core hay View?

Hiện `popTo(tag:)` khớp **hai** thứ: view push qua `pushView(tag:)`, và route
`.appFeature(tag)`. Xoá `appFeature` rồi thì tag **chỉ còn sinh ra từ `pushView`** → nó là
khái niệm của tầng View, phải nằm ở `KVViewRouting`. Plan ghi nó ở `KVRouting` là sai.

Với typed route thì không cần tag: `popTo(ShopRoute.cart)` đã có sẵn qua `popTo(_ route:)`.

### 5.3 Có expose state stack cho ViewModel không?

Bỏ `path` public thì VM mất khả năng hỏi "đang ở đâu". **✅ Đã chốt: thêm vào `KVRouting`:**

```swift
var stackDepth: Int { get }
var topRoute: (any KVRoute)? { get }
```

Read-only, **snapshot không observable** — có tài liệu ghi rõ. Đọc từ VM thì an toàn; đọc
trong `body` của View thì rơi vào bẫy iOS 16 (xem mục Observation của plan), nên không
khuyến khích và không hỗ trợ.

### 5.4 `popTo(where:)` giữ không?

Predicate thành `(any KVRoute) -> Bool` nên caller phải `as?` downcast — hơi thô. Nhưng
`popTo(_ route:)` đã lo case thường, đây là đường thoát hiểm hiếm dùng. Đề xuất **giữ**, không
thêm biến thể generic để tránh phình API.

---

## 6. Tổng kết số lượng

| | |
|---|---|
| API public hiện tại | ~100 declaration |
| Xoá | ~20 (modal 14, route model 2, builder 2, `handle(url:)`, `restorePath`) |
| Sang Core | 9 lệnh + 2 middleware + `KVLoggingMiddleware` |
| Sang View | phần còn lại, trong đó ~40 API transition không đổi một dòng |

Bề mặt public của 3.0 **nhỏ hơn** 2.0 dù thêm route model — chủ yếu vì cắt modal.
