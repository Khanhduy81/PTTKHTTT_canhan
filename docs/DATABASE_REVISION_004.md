# Database revision 004 — chứng từ, serial và bảo hành

Phạm vi: sửa 5 mục của lượt rà soát thứ hai. Thay đổi nằm trên nhánh `module-3`.

## Cài mới và nâng cấp

- Database demo mới: chạy `01_schema.sql` → `02_programmability.sql` → `03_seed.sql` như trước. **File 01 xoá database cũ.** Không chạy migration 004 sau cài mới.
- Database hiện có theo schema cũ: sao lưu, dừng các tiến trình ghi dữ liệu, thử trước trên bản sao. Chỉ chạy `database/migrations/004_documents_and_warranties.sql` bằng **sqlcmd -b** hoặc SSMS bật **SQLCMD Mode**. Script tự chứa schema và toàn bộ programmability cần thiết; không chạy file 01 và không seed lại.
- Ví dụ Windows Authentication, từ thư mục repo:

```powershell
sqlcmd -S localhost -E -b -i database/migrations/004_documents_and_warranties.sql
```

Migration dùng một transaction qua các batch GO, có `:ON ERROR EXIT`. Dừng lỗi và đóng kết nối sẽ rollback, không chạy tiếp thủ công từng đoạn. Script từ chối schema đã có revision này và từ chối dữ liệu cũ sai quan hệ/tổng tiền; sửa dữ liệu sau khi kiểm tra nguyên nhân rồi chạy lại. Không có thao tác xoá dữ liệu kinh doanh.

**Giới hạn dữ liệu lịch sử:** database cũ không lưu tên/SKU lúc mua, nên migration chỉ có thể lấy tên/SKU hiện tại. Billing ưu tiên hoá đơn đã phát hành, nếu chưa có thì lấy hồ sơ khách và địa chỉ giao hiện lưu trên đơn. Địa chỉ đã bị cắt ở bản cũ không thể tự phục hồi. Bản ghi bảo hành hàng không serial được bổ sung theo ngày duyệt và thời hạn đã lưu ở chi tiết; đơn đã huỷ nhận trạng thái Voided.

## Hợp đồng gọi database

### Đặt hàng và thông tin xuất hoá đơn

`sp_PlaceOrderFromCart` giữ nguyên các tham số cũ, thêm các tham số tuỳ chọn ở cuối:

| Tham số | Ý nghĩa |
|---|---|
| BillingName | Tên người mua trên hoá đơn; khác người nhận hàng |
| BillingCompany | Công ty xuất hoá đơn, có thể NULL |
| BillingTaxCode | Mã số thuế, có thể NULL |
| BillingAddress | Địa chỉ xuất hoá đơn; mặc định địa chỉ giao nếu không truyền |
| UseCustomerBilling | Mặc định 1: các trường tên/công ty/MST chưa truyền lấy từ hồ sơ lúc đặt. Đặt 0 khi người mua nhập riêng hoặc muốn xuất cá nhân không dùng công ty trong hồ sơ; khi đó phải truyền BillingName |

Khi duyệt, hoá đơn lấy hoàn toàn từ snapshot trên Orders, không đọc lại công ty/MST trong Customers. Địa chỉ ghép tối đa 506 ký tự được lưu trong NVARCHAR(600) ở biến, Orders và Invoices. Model nên bind các tham số chuỗi với đúng kiểu và độ dài; frontend cần kiểm tra độ dài đầu vào.

### Chi tiết đơn và in chứng từ

- OrderDetails thêm `ProductNameSnapshot`, `SkuSnapshot`, `IsSerialTrackedSnapshot`. Stored procedure tự điền; các luồng INSERT trực tiếp khác phải cung cấp các cột này.
- Đơn đã đặt không cho sửa/xoá/thêm tiếp dòng: muốn đổi hàng/số lượng thì huỷ và tạo đơn mới, để tồn giữ chỗ không lệch. Tất cả dòng được ghi trong **một INSERT** có tổng tiền khớp Orders.Subtotal.
- Không sửa thông tin tài chính/người mua/giao hàng của đơn đã tạo; hoá đơn chỉ được đổi trạng thái hoặc số lần in (IssuedAt vẫn cho phép thay đổi để tương thích seed demo lùi ngày).
- In chi tiết bằng `vw_InvoiceLines`, không join Products để lấy tên/SKU hiện tại. Không cần thêm bảng InvoiceDetails.
- Phiếu nhập chỉ sửa dòng ở Draft. Không đổi nội dung chính/xoá phiếu đã chốt; vẫn cho cập nhật thanh toán và hạn trả.

### Bảo hành và serial

- Hàng có serial: mỗi serial một bản ghi, CoveredQuantity=1.
- Hàng không serial: SerialId=NULL, một bản ghi theo OrderDetailId, CoveredQuantity bằng Quantity.
- Chỉ tự tạo bảo hành mới khi WarrantyMonths>0. Huỷ đơn vô hiệu cả hai loại.
- Tra cứu bằng `vw_WarrantyLookup`, lọc Phone, OrderNo hoặc SerialNumber; view LEFT JOIN serial nên không bỏ mất phụ kiện. Khi hiển thị hạn bảo hành dùng IsValid (có kiểm tra ngày), không chỉ Status.
- Một serial chỉ có một liên kết xuất bán hiện hành và một bảo hành Active. Sau huỷ, liên kết xuất được nhả, bảo hành Voided vẫn giữ làm lịch sử; serial được bán lại bình thường.
- Trigger chặn sai sản phẩm dòng nhập/dòng bán, sai khách trên bảo hành, sai số lượng, đổi chủ thể bảo hành và đổi chế độ serial sau khi sản phẩm đã phát sinh chứng từ.
- Đây không thay thế phân quyền tài khoản SQL. Ứng dụng phải gọi các thủ tục nghiệp vụ cho đặt/duyệt/huỷ/chốt phiếu, không tự cập nhật trạng thái hoặc tồn kho.

## Kiểm thử

Trên database thử nghiệm đã seed:

```powershell
sqlcmd -S localhost -E -b -i database/tests/004_documents_and_warranties.sql
```

Test dùng transaction rollback; sequence/identity có thể tăng dù rollback nên không chạy trên database thật. Bao gồm địa chỉ 506 ký tự, thông tin xuất hoá đơn độc lập, đổi hồ sơ/danh mục sau đặt, bảo hành phụ kiện, duyệt/huỷ và bán lại serial, các thao tác sửa chứng từ hoặc liên kết sai bị từ chối.

Chạy cả hai đường triển khai trên hai database thử nghiệm: (1) cài mới; (2) schema/seed bản cũ rồi migration. Kiểm tra rằng dữ liệu cũ vẫn còn, và chạy lại migration bị từ chối rõ ràng.

Môi trường soạn bản sửa không có SQL Server/sqlcmd; chưa xác nhận thực thi SQL. Đã kiểm tra diff, cấu trúc script/migration và tái sinh từ điển dữ liệu; bộ test trên cần chạy trước khi sử dụng thực tế.

Không xử lý trong revision này: hoàn tiền tự động, quyền huỷ đơn, khoá giỏ đồng thời, công thức lợi nhuận và các mục ngoài 1–5 của lượt rà soát thứ hai.
