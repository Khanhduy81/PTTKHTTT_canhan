# Laptop Shop — Frontend

Giao diện web responsive dựa trên [bản thiết kế Figma](https://www.figma.com/design/qnhMDYfSC0vDuZLbmD6WM7).

## Chạy

Chạy giao diện ngay trong app Express hiện tại bằng `npm run dev` ở thư mục gốc, rồi mở **http://localhost:3000/customer-ui/**.

Hoặc chạy bản UI độc lập (không cần SQL Server) bằng Node.js 18 trở lên:

```bash
cd src/views/customer/ui-preview
npm start
```

Mở **http://localhost:3000**. Không cần cài thư viện hoặc database.

## Phân công

| Module | Phụ trách | Phạm vi |
| --- | --- | --- |
| 1 | Kiệt | Hệ thống, phân quyền, đăng nhập, nhật ký, nhà cung cấp, nhập kho và tồn kho |
| 2 | Tấn | Danh mục và cửa hàng: sản phẩm, thương hiệu, thuộc tính, trang chủ, tìm/lọc/xem |
| **3** | **Duy** | **Khách mua hàng: đăng ký, hồ sơ, giỏ hàng, thanh toán, đặt hàng, lịch sử và hủy đơn** |
| 4 | Huy | Duyệt/hủy đơn cho nhân viên, hóa đơn, doanh thu, bảo hành |

## Màn hình

Trang chủ, danh sách sản phẩm, chi tiết sản phẩm, đăng nhập, đăng ký, quên/đặt lại mật khẩu, giỏ hàng, giỏ hàng trống, thanh toán, đặt hàng thành công, hồ sơ, địa chỉ, đổi mật khẩu, lịch sử đơn, chi tiết đơn và hủy đơn. Có các trang thông tin giới thiệu, liên hệ, hướng dẫn và chính sách. Mọi màn hình tự thích ứng desktop/mobile.

Các đường dẫn giao diện dùng hash, ví dụ `/#/cart`, `/#/profile`, `/#/orders`, `/#/cart-empty`, `/#/reset`, `/#/success`.

## Giới hạn và tích hợp

**Chỉ có UI và điều hướng, chưa có logic nghiệp vụ.** Giá, sản phẩm, tài khoản, đơn hàng và liên hệ là dữ liệu mẫu. Không tạo tài khoản, đăng nhập, tìm/lọc/sắp xếp, cập nhật số lượng/tổng tiền, áp mã, lưu hồ sơ/địa chỉ, xử lý thanh toán hoặc tạo/hủy đơn thật. Nút thao tác và submit form hiển thị thông báo giao diện mẫu. Không có API hoặc lưu trữ dữ liệu.

- `public/app.js` (trong thư mục ui-preview): hàm render từng màn hình; `PRODUCTS`, `ORDERS` là dữ liệu mẫu. Thay bằng dữ liệu từ API khi làm nghiệp vụ.
- `public/styles.css`: các biến màu, layout và breakpoint responsive.
- `public/assets/`: SVG minh họa; thay bằng ảnh sản phẩm thật sau.
- `server.js`: máy chủ file tĩnh sử dụng Node.js thuần, không phải backend nghiệp vụ.

Khi chuyển sang Express/MVC, có thể tách các hàm UI của module 3 thành template `views/customer/`, stylesheet/assets vào `public/`, rồi nối với `routes/customer.routes.js`, `controllers/customer/`, `models/{customer,cart,checkout,customerOrder}.model.js`. Không cần thay đổi phân công hiện tại.

Chạy kiểm tra cú pháp bằng `npm run check`.

## Kiểm tra trước khi push

Đã kiểm tra cú pháp JavaScript, render 24 đường dẫn bằng Node VM và phục vụ các file tĩnh qua HTTP. Môi trường kiểm tra không có Chromium nên chưa chạy kiểm tra hình bằng trình duyệt.
