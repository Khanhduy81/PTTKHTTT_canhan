/* =====================================================================
   File 02: TRIGGER + VIEW + STORED PROCEDURE  (yêu cầu SQL Server 2017+)
   Nghiệp vụ lõi (đặt / duyệt / huỷ đơn, nhập kho) nằm trong Stored Procedure
   để bảo đảm toàn vẹn dữ liệu bằng transaction. Node.js chỉ gọi EXEC.
   Mã lỗi nghiệp vụ: THROW 50xxx (Node bắt err.number để hiển thị thông báo).
   ===================================================================== */
USE LaptopShopDB;
GO

-- (Trigger tự tạo dòng Inventory đã bỏ - QtyOnHand/QtyReserved/ReorderLevel nay là cột của Products,
--  có DEFAULT sẵn nên không cần trigger khi thêm sản phẩm)

/* ---------- VIEW ---------- */

-- Danh sách sản phẩm cho cửa hàng: kèm danh mục, thương hiệu, ảnh đại diện, tồn có thể bán
CREATE OR ALTER VIEW dbo.vw_ProductCatalog
AS
SELECT  p.ProductId, p.Sku, p.ProductName, p.Slug, p.ShortDesc,
        p.SalePrice, p.CostPrice, p.WarrantyMonths, p.IsSerialTracked, p.IsActive,
        p.CategoryId, c.CategoryName, c.ParentId AS CategoryParentId,
        p.BrandId, b.BrandName,
        p.QtyOnHand, p.QtyReserved, (p.QtyOnHand - p.QtyReserved) AS QtyAvailable, p.ReorderLevel,
        img.ImageUrl AS PrimaryImage
FROM    dbo.Products p
JOIN    dbo.Categories c ON c.CategoryId = p.CategoryId
JOIN    dbo.Brands b     ON b.BrandId = p.BrandId
LEFT JOIN dbo.ProductImages img ON img.ProductId = p.ProductId AND img.IsPrimary = 1;
GO

-- Sản phẩm sắp hết hàng (tồn có thể bán <= ngưỡng)
CREATE OR ALTER VIEW dbo.vw_LowStock
AS
SELECT  ProductId, Sku, ProductName, CategoryName, BrandName, QtyOnHand, QtyReserved, QtyAvailable, ReorderLevel
FROM    dbo.vw_ProductCatalog
WHERE   IsActive = 1 AND QtyAvailable <= ReorderLevel;
GO

-- Doanh thu theo ngày (tính theo ngày duyệt của đơn Approved/Completed)
CREATE OR ALTER VIEW dbo.vw_SalesDaily
AS
SELECT  CAST(o.ApprovedAt AS DATE) AS SaleDate,
        COUNT(*)                   AS OrderCount,
        SUM(o.Subtotal)            AS GrossAmount,
        SUM(o.DiscountAmount)      AS DiscountAmount,
        SUM(o.VatAmount)           AS VatAmount,
        SUM(o.TotalAmount)         AS Revenue
FROM    dbo.Orders o
WHERE   o.Status IN ('Approved','Completed') AND o.ApprovedAt IS NOT NULL
GROUP BY CAST(o.ApprovedAt AS DATE);
GO

-- Doanh số + lợi nhuận gộp theo sản phẩm (sản phẩm bán chạy)
CREATE OR ALTER VIEW dbo.vw_ProductSales
AS
SELECT  p.ProductId, p.Sku, p.ProductName, c.CategoryName, b.BrandName,
        SUM(d.Quantity)                              AS QtySold,
        SUM(d.LineTotal)                             AS SalesAmount,
        SUM(d.LineTotal - d.Quantity * d.CostPrice)  AS GrossProfit
FROM    dbo.OrderDetails d
JOIN    dbo.Orders o     ON o.OrderId = d.OrderId AND o.Status IN ('Approved','Completed')
JOIN    dbo.Products p   ON p.ProductId = d.ProductId
JOIN    dbo.Categories c ON c.CategoryId = p.CategoryId
JOIN    dbo.Brands b     ON b.BrandId = p.BrandId
GROUP BY p.ProductId, p.Sku, p.ProductName, c.CategoryName, b.BrandName;
GO

-- Công nợ phải trả nhà cung cấp
CREATE OR ALTER VIEW dbo.vw_SupplierPayables
AS
SELECT  s.SupplierId, s.SupplierName,
        SUM(g.TotalAmount)                 AS TotalPurchased,
        SUM(g.PaidAmount)                  AS TotalPaid,
        SUM(g.TotalAmount - g.PaidAmount)  AS Outstanding
FROM    dbo.Suppliers s
JOIN    dbo.GoodsReceipts g ON g.SupplierId = s.SupplierId AND g.Status = 'Posted'
GROUP BY s.SupplierId, s.SupplierName;
GO

/* ---------- STORED PROCEDURE: NHẬP KHO ---------- */
-- Chốt phiếu nhập: Draft -> Posted. Cộng tồn, kích hoạt serial, cập nhật giá vốn, ghi sổ kho.
-- Node phải INSERT sẵn GoodsReceipts(Draft) + GoodsReceiptDetails + ProductSerials(Pending) trong 1 transaction.
CREATE OR ALTER PROCEDURE dbo.sp_PostGoodsReceipt
    @ReceiptId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @Status VARCHAR(10);
    SELECT @Status = Status FROM dbo.GoodsReceipts WITH (UPDLOCK, ROWLOCK) WHERE ReceiptId = @ReceiptId;

    IF @Status IS NULL THROW 50040, N'Phiếu nhập không tồn tại.', 1;
    IF @Status <> 'Draft' THROW 50041, N'Chỉ chốt được phiếu nhập ở trạng thái Nháp.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.GoodsReceiptDetails WHERE ReceiptId = @ReceiptId)
        THROW 50042, N'Phiếu nhập chưa có dòng chi tiết.', 1;

    -- Sản phẩm quản lý serial: số serial nhập phải đúng bằng số lượng
    IF EXISTS (
        SELECT 1
        FROM dbo.GoodsReceiptDetails d
        JOIN dbo.Products p ON p.ProductId = d.ProductId
        WHERE d.ReceiptId = @ReceiptId AND p.IsSerialTracked = 1
          AND d.Quantity <> (SELECT COUNT(*) FROM dbo.ProductSerials s WHERE s.ReceiptDetailId = d.ReceiptDetailId)
    )
        THROW 50043, N'Số lượng Serial nhập không khớp số lượng sản phẩm quản lý theo Serial.', 1;

    IF EXISTS (
        SELECT 1 FROM dbo.ProductSerials s
        JOIN dbo.GoodsReceiptDetails d ON d.ReceiptDetailId = s.ReceiptDetailId
        JOIN dbo.Products p ON p.ProductId = d.ProductId
        WHERE d.ReceiptId = @ReceiptId
          AND (s.ProductId <> d.ProductId OR s.Status <> 'Pending' OR p.IsSerialTracked = 0)
    ) THROW 50044, N'Serial phải thuộc đúng sản phẩm quản lý serial và đang Pending.', 1;

    UPDATE s SET s.Status = 'InStock'
    FROM dbo.ProductSerials s
    JOIN dbo.GoodsReceiptDetails d ON d.ReceiptDetailId = s.ReceiptDetailId
    WHERE d.ReceiptId = @ReceiptId AND s.Status = 'Pending';

    UPDATE p SET p.QtyOnHand = p.QtyOnHand + d.Quantity, p.CostPrice = d.UnitCost, p.UpdatedAt = SYSDATETIME()
    FROM dbo.Products p
    JOIN dbo.GoodsReceiptDetails d ON d.ProductId = p.ProductId
    WHERE d.ReceiptId = @ReceiptId;

    INSERT INTO dbo.AuditLogs (AccountId, Action, EntityName, EntityId, Detail)
    SELECT NULL, 'STOCK_IN', 'Product', CAST(d.ProductId AS VARCHAR(50)),
           CONCAT(N'Nhập kho +', d.Quantity, N' theo phiếu nhập #', @ReceiptId)
    FROM dbo.GoodsReceiptDetails d
    WHERE d.ReceiptId = @ReceiptId;

    UPDATE g SET g.Status = 'Posted',
                 g.TotalAmount = (SELECT SUM(LineTotal) FROM dbo.GoodsReceiptDetails WHERE ReceiptId = @ReceiptId),
                 g.DueDate = DATEADD(DAY, sp.PaymentTermDays, CAST(g.ReceiptDate AS DATE))
    FROM dbo.GoodsReceipts g
    JOIN dbo.Suppliers sp ON sp.SupplierId = g.SupplierId
    WHERE g.ReceiptId = @ReceiptId;

    COMMIT TRAN;
END
GO

/* ---------- STORED PROCEDURE: ĐẶT HÀNG TỪ GIỎ ---------- */
-- Tạo đơn Pending từ giỏ hàng của khách, GIỮ CHỖ tồn kho (QtyReserved), áp voucher, xoá giỏ.
CREATE OR ALTER PROCEDURE dbo.sp_PlaceOrderFromCart
    @CustomerId    INT,
    @AddressId     INT,
    @PaymentMethod VARCHAR(15),
    @PromoCode     VARCHAR(30)   = NULL,
    @Note          NVARCHAR(500) = NULL,
    @OrderId       INT           OUTPUT,
    @BillingName   NVARCHAR(100) = NULL,
    @BillingCompany NVARCHAR(200) = NULL,
    @BillingTaxCode VARCHAR(20) = NULL,
    @BillingAddress NVARCHAR(600) = NULL,
    @UseCustomerBilling BIT = 1 -- 1: mặc định hồ sơ khách; 0: dùng đầy đủ thông tin xuất hoá đơn truyền vào
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @CartId INT, @ItemCount INT, @Affected INT;
    DECLARE @Subtotal DECIMAL(18,0), @Discount DECIMAL(18,0) = 0, @Ship DECIMAL(18,0);
    DECLARE @PromoId INT = NULL, @PType VARCHAR(10), @PVal DECIMAL(18,2), @PMax DECIMAL(18,0);
    DECLARE @RName NVARCHAR(100), @RPhone VARCHAR(15), @Addr NVARCHAR(600);
    DECLARE @Seq INT, @OrderNo VARCHAR(20);

    SELECT @CartId = CartId FROM dbo.Carts WHERE CustomerId = @CustomerId;
    SELECT @ItemCount = COUNT(*) FROM dbo.CartItems WHERE CartId = @CartId;
    IF @CartId IS NULL OR @ItemCount = 0 THROW 50020, N'Giỏ hàng trống.', 1;

    IF EXISTS (SELECT 1 FROM dbo.CartItems ci JOIN dbo.Products p ON p.ProductId = ci.ProductId
               WHERE ci.CartId = @CartId AND p.IsActive = 0)
        THROW 50023, N'Giỏ hàng có sản phẩm đã ngừng bán.', 1;

    SELECT @RName = ReceiverName, @RPhone = ReceiverPhone,
           @Addr = CONCAT_WS(N', ', AddressLine, Ward, District, Province)
    FROM dbo.CustomerAddresses WHERE AddressId = @AddressId AND CustomerId = @CustomerId;
    IF @RName IS NULL THROW 50024, N'Địa chỉ giao hàng không hợp lệ.', 1;

    IF @UseCustomerBilling = 1
        SELECT @BillingName = COALESCE(@BillingName, FullName),
               @BillingCompany = COALESCE(@BillingCompany, CompanyName),
               @BillingTaxCode = COALESCE(@BillingTaxCode, TaxCode)
        FROM dbo.Customers WHERE CustomerId = @CustomerId;
    SET @BillingAddress = COALESCE(@BillingAddress, @Addr);
    IF NULLIF(LTRIM(RTRIM(@BillingName)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@BillingAddress)), N'') IS NULL
        THROW 50025, N'Thiếu tên hoặc địa chỉ xuất hoá đơn.', 1;


    -- Giữ chỗ tồn kho: chỉ cập nhật được nếu tồn có thể bán >= số lượng đặt
    UPDATE p SET p.QtyReserved = p.QtyReserved + ci.Quantity, p.UpdatedAt = SYSDATETIME()
    FROM dbo.Products p
    JOIN dbo.CartItems ci ON ci.ProductId = p.ProductId
    WHERE ci.CartId = @CartId AND (p.QtyOnHand - p.QtyReserved) >= ci.Quantity;
    SET @Affected = @@ROWCOUNT;
    IF @Affected <> @ItemCount THROW 50021, N'Một số sản phẩm không đủ tồn kho.', 1;

    SELECT @Subtotal = SUM(ci.Quantity * p.SalePrice)
    FROM dbo.CartItems ci JOIN dbo.Products p ON p.ProductId = ci.ProductId
    WHERE ci.CartId = @CartId;

    IF @PromoCode IS NOT NULL AND LEN(@PromoCode) > 0
    BEGIN
        SELECT @PromoId = PromotionId, @PType = DiscountType, @PVal = DiscountValue, @PMax = MaxDiscount
        FROM dbo.Promotions WITH (UPDLOCK)
        WHERE Code = @PromoCode AND IsActive = 1
          AND SYSDATETIME() BETWEEN StartDate AND EndDate
          AND (UsageLimit IS NULL OR UsedCount < UsageLimit)
          AND @Subtotal >= MinOrderAmount;
        IF @PromoId IS NULL THROW 50022, N'Mã khuyến mãi không hợp lệ hoặc không đủ điều kiện.', 1;

        SET @Discount = CASE WHEN @PType = 'Percent' THEN ROUND(@Subtotal * @PVal / 100, 0) ELSE @PVal END;
        IF @PType = 'Percent' AND @PMax IS NOT NULL AND @Discount > @PMax SET @Discount = @PMax;
        IF @Discount > @Subtotal SET @Discount = @Subtotal;

        UPDATE dbo.Promotions SET UsedCount = UsedCount + 1 WHERE PromotionId = @PromoId;
    END

    SET @Ship = CASE WHEN @Subtotal >= 5000000 THEN 0 ELSE 30000 END;   -- miễn phí ship từ 5 triệu

    SELECT @Seq = NEXT VALUE FOR dbo.sq_OrderNo;
    SET @OrderNo = 'DH' + FORMAT(SYSDATETIME(), 'yyMM') + '-' + RIGHT('00000' + CAST(@Seq AS VARCHAR(10)), 5);

    INSERT INTO dbo.Orders (OrderNo, CustomerId, PromotionId, Status, PaymentMethod, PaymentStatus, ReceiverName, ReceiverPhone,
                            ShippingAddress, BillingName, BillingCompany, BillingTaxCode, BillingAddress, Subtotal, DiscountAmount, ShippingFee, Note)
    VALUES (@OrderNo, @CustomerId, @PromoId, 'Pending', @PaymentMethod, 'Pending', @RName, @RPhone,
            @Addr, @BillingName, @BillingCompany, @BillingTaxCode, @BillingAddress, @Subtotal, @Discount, @Ship, @Note);
    SET @OrderId = CAST(SCOPE_IDENTITY() AS INT);

    INSERT INTO dbo.OrderDetails (OrderId, ProductId, ProductNameSnapshot, SkuSnapshot, IsSerialTrackedSnapshot, Quantity, UnitPrice, CostPrice, WarrantyMonths)
    SELECT @OrderId, ci.ProductId, p.ProductName, p.Sku, p.IsSerialTracked, ci.Quantity, p.SalePrice, p.CostPrice, p.WarrantyMonths
    FROM dbo.CartItems ci JOIN dbo.Products p ON p.ProductId = ci.ProductId
    WHERE ci.CartId = @CartId;

    INSERT INTO dbo.AuditLogs (AccountId, Action, EntityName, EntityId, Detail)
    SELECT c.AccountId, 'CREATE', 'Order', CAST(@OrderId AS VARCHAR(50)), N'Khách đặt hàng'
    FROM dbo.Customers c WHERE c.CustomerId = @CustomerId;

    DELETE FROM dbo.CartItems WHERE CartId = @CartId;
    UPDATE dbo.Carts SET UpdatedAt = SYSDATETIME() WHERE CartId = @CartId;

    COMMIT TRAN;
END
GO

/* ---------- STORED PROCEDURE: DUYỆT ĐƠN ---------- */
-- Pending -> Approved: trừ tồn thật, gán serial (FIFO), tạo bảo hành điện tử, ghi sổ kho, phát hành hoá đơn.
CREATE OR ALTER PROCEDURE dbo.sp_ApproveOrder
    @OrderId   INT,
    @AccountId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @Status VARCHAR(10), @EmployeeId INT, @Expected INT, @Assigned INT;
    DECLARE @Seq INT, @InvoiceNo VARCHAR(20);

    SELECT @EmployeeId = EmployeeId FROM dbo.Employees WHERE AccountId = @AccountId;
    IF @EmployeeId IS NULL THROW 50030, N'Tài khoản không phải nhân viên.', 1;

    SELECT @Status = Status FROM dbo.Orders WITH (UPDLOCK, ROWLOCK) WHERE OrderId = @OrderId;
    IF @Status IS NULL THROW 50031, N'Đơn hàng không tồn tại.', 1;
    IF @Status <> 'Pending' THROW 50032, N'Chỉ duyệt được đơn ở trạng thái Chờ duyệt.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.OrderDetails WHERE OrderId = @OrderId)
       OR EXISTS (SELECT 1 FROM dbo.Orders o WHERE o.OrderId = @OrderId AND
          o.Subtotal <> (SELECT SUM(LineTotal) FROM dbo.OrderDetails WHERE OrderId = @OrderId))
        THROW 50034, N'Tổng tiền đơn không khớp chi tiết hoặc đơn trống.', 1;


    -- 1) Trừ tồn thực tế + bỏ giữ chỗ
    UPDATE p SET p.QtyOnHand = p.QtyOnHand - d.Quantity,
                 p.QtyReserved = p.QtyReserved - d.Quantity,
                 p.UpdatedAt = SYSDATETIME()
    FROM dbo.Products p
    JOIN dbo.OrderDetails d ON d.ProductId = p.ProductId
    WHERE d.OrderId = @OrderId;

    -- 2) Gán serial cho sản phẩm quản lý theo serial (lấy serial nhập sớm nhất)
    SELECT @Expected = ISNULL(SUM(d.Quantity), 0)
    FROM dbo.OrderDetails d JOIN dbo.Products p ON p.ProductId = d.ProductId
    WHERE d.OrderId = @OrderId AND d.IsSerialTrackedSnapshot = 1;

    ;WITH need AS (
        SELECT d.OrderDetailId, d.ProductId, d.Quantity
        FROM dbo.OrderDetails d JOIN dbo.Products p ON p.ProductId = d.ProductId
        WHERE d.OrderId = @OrderId AND d.IsSerialTrackedSnapshot = 1
    ),
    ranked AS (
        SELECT s.SerialId, s.ProductId,
               ROW_NUMBER() OVER (PARTITION BY s.ProductId ORDER BY s.SerialId) AS rn
        FROM dbo.ProductSerials s WITH (UPDLOCK)
        WHERE s.Status = 'InStock' AND s.ProductId IN (SELECT ProductId FROM need)
    )
    INSERT INTO dbo.OrderDetailSerials (OrderDetailId, SerialId)
    SELECT n.OrderDetailId, r.SerialId
    FROM need n JOIN ranked r ON r.ProductId = n.ProductId AND r.rn <= n.Quantity;
    SET @Assigned = @@ROWCOUNT;
    IF @Assigned <> @Expected THROW 50033, N'Không đủ Serial "Trong kho" để xuất cho đơn hàng.', 1;

    UPDATE s SET s.Status = 'Sold'
    FROM dbo.ProductSerials s
    JOIN dbo.OrderDetailSerials ods ON ods.SerialId = s.SerialId
    JOIN dbo.OrderDetails d ON d.OrderDetailId = ods.OrderDetailId
    WHERE d.OrderId = @OrderId;

    -- 3) Bảo hành: mỗi serial một dòng; hàng không serial một dòng cho toàn bộ số lượng.
    INSERT INTO dbo.Warranties (SerialId, CoveredQuantity, OrderDetailId, CustomerId, StartDate, EndDate)
    SELECT ods.SerialId, 1, d.OrderDetailId, o.CustomerId,
           CAST(SYSDATETIME() AS DATE), DATEADD(MONTH, d.WarrantyMonths, CAST(SYSDATETIME() AS DATE))
    FROM dbo.OrderDetailSerials ods
    JOIN dbo.OrderDetails d ON d.OrderDetailId = ods.OrderDetailId
    JOIN dbo.Orders o ON o.OrderId = d.OrderId
    WHERE d.OrderId = @OrderId AND d.WarrantyMonths > 0;

    INSERT INTO dbo.Warranties (SerialId, CoveredQuantity, OrderDetailId, CustomerId, StartDate, EndDate)
    SELECT NULL, d.Quantity, d.OrderDetailId, o.CustomerId,
           CAST(SYSDATETIME() AS DATE), DATEADD(MONTH, d.WarrantyMonths, CAST(SYSDATETIME() AS DATE))
    FROM dbo.OrderDetails d JOIN dbo.Orders o ON o.OrderId = d.OrderId
    WHERE d.OrderId = @OrderId AND d.IsSerialTrackedSnapshot = 0 AND d.WarrantyMonths > 0;

    -- 4) Sổ kho (ghi qua AuditLogs dùng chung)
    INSERT INTO dbo.AuditLogs (AccountId, Action, EntityName, EntityId, Detail)
    SELECT @AccountId, 'STOCK_OUT', 'Product', CAST(d.ProductId AS VARCHAR(50)),
           CONCAT(N'Xuất kho -', d.Quantity, N' khi duyệt đơn #', @OrderId)
    FROM dbo.OrderDetails d WHERE d.OrderId = @OrderId;

    -- 5) Hoá đơn
    SELECT @Seq = NEXT VALUE FOR dbo.sq_InvoiceNo;
    SET @InvoiceNo = 'HD' + FORMAT(SYSDATETIME(), 'yyMM') + '-' + RIGHT('00000' + CAST(@Seq AS VARCHAR(10)), 5);

    INSERT INTO dbo.Invoices (InvoiceNo, OrderId, IssuedByEmployee, BuyerName, BuyerCompany, BuyerTaxCode, BuyerAddress,
                              SubtotalAmount, DiscountAmount, VatAmount, TotalAmount)
    SELECT @InvoiceNo, o.OrderId, @EmployeeId, o.BillingName, o.BillingCompany, o.BillingTaxCode, o.BillingAddress,
           o.Subtotal, o.DiscountAmount, o.VatAmount, o.TotalAmount
    FROM dbo.Orders o
    WHERE o.OrderId = @OrderId;

    -- 6) Đổi trạng thái đơn
    UPDATE dbo.Orders SET Status = 'Approved', SalesEmployeeId = @EmployeeId, ApprovedAt = SYSDATETIME()
    WHERE OrderId = @OrderId;

    INSERT INTO dbo.AuditLogs (AccountId, Action, EntityName, EntityId, Detail)
    VALUES (@AccountId, 'APPROVE', 'Order', CAST(@OrderId AS VARCHAR(50)), N'Nhân viên duyệt đơn (Pending -> Approved)');

    COMMIT TRAN;
END
GO

/* ---------- STORED PROCEDURE: HUỶ ĐƠN ---------- */
-- Pending  -> Cancelled : nhả giữ chỗ tồn kho.
-- Approved -> Cancelled : TRẢ LẠI tồn kho, trả serial về "Trong kho", vô hiệu bảo hành + hoá đơn.
CREATE OR ALTER PROCEDURE dbo.sp_CancelOrder
    @OrderId   INT,
    @Reason    NVARCHAR(255),
    @AccountId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @Status VARCHAR(10), @PromoId INT;
    SELECT @Status = Status, @PromoId = PromotionId
    FROM dbo.Orders WITH (UPDLOCK, ROWLOCK) WHERE OrderId = @OrderId;

    IF @Status IS NULL THROW 50035, N'Đơn hàng không tồn tại.', 1;
    IF @Status IN ('Cancelled', 'Completed') THROW 50036, N'Không thể huỷ đơn đã huỷ hoặc đã hoàn tất.', 1;

    IF @Status = 'Pending'
    BEGIN
        UPDATE p SET p.QtyReserved = p.QtyReserved - d.Quantity, p.UpdatedAt = SYSDATETIME()
        FROM dbo.Products p JOIN dbo.OrderDetails d ON d.ProductId = p.ProductId
        WHERE d.OrderId = @OrderId;
    END
    ELSE   -- Approved
    BEGIN
        UPDATE p SET p.QtyOnHand = p.QtyOnHand + d.Quantity, p.UpdatedAt = SYSDATETIME()
        FROM dbo.Products p JOIN dbo.OrderDetails d ON d.ProductId = p.ProductId
        WHERE d.OrderId = @OrderId;

        INSERT INTO dbo.AuditLogs (AccountId, Action, EntityName, EntityId, Detail)
        SELECT @AccountId, 'STOCK_IN', 'Product', CAST(d.ProductId AS VARCHAR(50)),
               CONCAT(N'Trả kho +', d.Quantity, N' do huỷ đơn #', @OrderId)
        FROM dbo.OrderDetails d WHERE d.OrderId = @OrderId;

        UPDATE s SET s.Status = 'InStock'
        FROM dbo.ProductSerials s
        JOIN dbo.OrderDetailSerials ods ON ods.SerialId = s.SerialId
        JOIN dbo.OrderDetails d ON d.OrderDetailId = ods.OrderDetailId
        WHERE d.OrderId = @OrderId;

        UPDATE w SET w.Status = 'Voided'
        FROM dbo.Warranties w
        JOIN dbo.OrderDetails d ON d.OrderDetailId = w.OrderDetailId
        WHERE d.OrderId = @OrderId;

        DELETE ods
        FROM dbo.OrderDetailSerials ods
        JOIN dbo.OrderDetails d ON d.OrderDetailId = ods.OrderDetailId
        WHERE d.OrderId = @OrderId;

        UPDATE dbo.Invoices SET Status = 'Voided' WHERE OrderId = @OrderId;
    END

    IF @PromoId IS NOT NULL
        UPDATE dbo.Promotions SET UsedCount = UsedCount - 1 WHERE PromotionId = @PromoId AND UsedCount > 0;

    UPDATE dbo.Orders
    SET Status = 'Cancelled', CancelReason = @Reason, CancelledAt = SYSDATETIME(),
        PaymentStatus = CASE WHEN PaymentStatus = 'Paid' THEN 'Refunded' ELSE PaymentStatus END
    WHERE OrderId = @OrderId;

    INSERT INTO dbo.AuditLogs (AccountId, Action, EntityName, EntityId, Detail)
    VALUES (@AccountId, 'CANCEL', 'Order', CAST(@OrderId AS VARCHAR(50)), CONCAT(@Status, N' -> Cancelled: ', @Reason));

    COMMIT TRAN;
END
GO


CREATE OR ALTER VIEW dbo.vw_WarrantyLookup
AS
SELECT w.WarrantyId, w.SerialId, s.SerialNumber, w.OrderDetailId,
       w.CustomerId, c.FullName, c.Phone, d.OrderId, o.OrderNo,
       d.ProductId, d.ProductNameSnapshot AS ProductName, d.SkuSnapshot AS Sku,
       w.CoveredQuantity, w.StartDate, w.EndDate, w.Status,
       CAST(CASE WHEN w.Status = 'Active' AND CAST(SYSDATETIME() AS DATE)
            BETWEEN w.StartDate AND w.EndDate THEN 1 ELSE 0 END AS BIT) AS IsValid
FROM dbo.Warranties w
JOIN dbo.OrderDetails d ON d.OrderDetailId = w.OrderDetailId
JOIN dbo.Orders o ON o.OrderId = d.OrderId
JOIN dbo.Customers c ON c.CustomerId = w.CustomerId
LEFT JOIN dbo.ProductSerials s ON s.SerialId = w.SerialId;
GO

/* ---------- TOÀN VẸN CHỨNG TỪ (set-based, hỗ trợ nhiều dòng) ---------- */
-- Đơn đã đặt không sửa dòng: huỷ và đặt lại để giữ đúng QtyReserved.
CREATE OR ALTER TRIGGER dbo.tr_OrderDetails_Immutable
ON dbo.OrderDetails AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    IF EXISTS (SELECT 1 FROM deleted)
        THROW 50101, N'Không sửa/xoá chi tiết đơn đã đặt; hãy huỷ và đặt lại.', 1;
    IF EXISTS (
        SELECT 1 FROM inserted i JOIN dbo.Orders o WITH (UPDLOCK, HOLDLOCK) ON o.OrderId = i.OrderId
        WHERE o.Status <> 'Pending'
    ) THROW 50102, N'Chỉ thêm chi tiết khi đơn đang Pending.', 1;
    IF EXISTS (SELECT 1 FROM dbo.OrderDetails d JOIN inserted i ON i.OrderId = d.OrderId
               WHERE NOT EXISTS (SELECT 1 FROM inserted x WHERE x.OrderDetailId = d.OrderDetailId))
        THROW 50118, N'Không thêm dòng vào đơn đã có chi tiết; hãy huỷ và đặt lại.', 1;
    IF EXISTS (
        SELECT 1 FROM dbo.Orders o JOIN (SELECT DISTINCT OrderId FROM inserted) a ON a.OrderId = o.OrderId
        WHERE o.Subtotal <> (SELECT SUM(LineTotal) FROM dbo.OrderDetails d WHERE d.OrderId = o.OrderId)
    ) THROW 50103, N'Phải ghi đầy đủ chi tiết trong một INSERT, tổng tiền phải khớp đơn.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_Orders_Snapshot
ON dbo.Orders AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT OrderId, OrderNo, CustomerId, PromotionId, PaymentMethod, ReceiverName, ReceiverPhone,
               ShippingAddress, BillingName, BillingCompany, BillingTaxCode, BillingAddress,
               Subtotal, DiscountAmount, ShippingFee, VatRate FROM inserted
        EXCEPT
        SELECT OrderId, OrderNo, CustomerId, PromotionId, PaymentMethod, ReceiverName, ReceiverPhone,
               ShippingAddress, BillingName, BillingCompany, BillingTaxCode, BillingAddress,
               Subtotal, DiscountAmount, ShippingFee, VatRate FROM deleted
    ) THROW 50104, N'Không thay đổi thông tin/giá trị đơn đã đặt; hãy huỷ và đặt lại.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_GoodsReceiptDetails_DraftOnly
ON dbo.GoodsReceiptDetails AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM dbo.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK)
        JOIN (SELECT ReceiptId FROM inserted UNION SELECT ReceiptId FROM deleted) a ON a.ReceiptId = g.ReceiptId
        WHERE g.Status <> 'Draft'
    ) THROW 50105, N'Chỉ được sửa chi tiết phiếu nhập Nháp.', 1;
    IF EXISTS (
        SELECT 1 FROM inserted i JOIN dbo.ProductSerials s ON s.ReceiptDetailId = i.ReceiptDetailId
        WHERE s.ProductId <> i.ProductId
    ) THROW 50106, N'Sản phẩm dòng nhập không khớp serial đã khai báo.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_GoodsReceipts_ProtectPosted
ON dbo.GoodsReceipts AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT d.ReceiptId, d.ReceiptNo, d.SupplierId, d.EmployeeId, d.ReceiptDate, d.Status, d.TotalAmount
        FROM deleted d WHERE d.Status <> 'Draft'
        EXCEPT
        SELECT i.ReceiptId, i.ReceiptNo, i.SupplierId, i.EmployeeId, i.ReceiptDate, i.Status, i.TotalAmount FROM inserted i
    ) THROW 50107, N'Không sửa/xoá nội dung phiếu nhập đã chốt hoặc đã huỷ.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_ProductSerials_Integrity
ON dbo.ProductSerials AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM inserted i
        JOIN dbo.GoodsReceiptDetails d ON d.ReceiptDetailId = i.ReceiptDetailId
        JOIN dbo.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK) ON g.ReceiptId = d.ReceiptId
        JOIN dbo.Products p ON p.ProductId = i.ProductId
        WHERE i.ProductId <> d.ProductId OR p.IsSerialTracked = 0
           OR ((NOT EXISTS (SELECT 1 FROM deleted old WHERE old.SerialId = i.SerialId)
                OR EXISTS (SELECT 1 FROM deleted old WHERE old.SerialId = i.SerialId
                           AND (old.ReceiptDetailId <> i.ReceiptDetailId OR old.ProductId <> i.ProductId)))
               AND (g.Status <> 'Draft' OR i.Status <> 'Pending'))
    ) THROW 50108, N'Serial mới phải Pending, thuộc đúng sản phẩm quản lý serial của phiếu Nháp.', 1;
    IF EXISTS (
        SELECT d.SerialId, d.ProductId, d.SerialNumber, d.ReceiptDetailId
        FROM deleted d
        JOIN dbo.GoodsReceiptDetails gd ON gd.ReceiptDetailId = d.ReceiptDetailId
        JOIN dbo.GoodsReceipts g WITH (UPDLOCK, HOLDLOCK) ON g.ReceiptId = gd.ReceiptId
        WHERE g.Status <> 'Draft'
        EXCEPT SELECT SerialId, ProductId, SerialNumber, ReceiptDetailId FROM inserted
    ) THROW 50109, N'Không sửa định danh hoặc xoá serial của phiếu đã chốt.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_OrderDetailSerials_Integrity
ON dbo.OrderDetailSerials AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)
        THROW 50110, N'Không đổi liên kết serial đã xuất.', 1;
    IF EXISTS (
        SELECT 1 FROM inserted i
        JOIN dbo.OrderDetails d ON d.OrderDetailId = i.OrderDetailId
        JOIN dbo.Orders o WITH (UPDLOCK, HOLDLOCK) ON o.OrderId = d.OrderId
        JOIN dbo.ProductSerials s WITH (UPDLOCK, HOLDLOCK) ON s.SerialId = i.SerialId
        WHERE d.ProductId <> s.ProductId OR d.IsSerialTrackedSnapshot = 0
           OR s.Status <> 'InStock' OR o.Status <> 'Pending'
    ) THROW 50111, N'Serial phải đúng sản phẩm, còn trong kho và đơn đang Pending.', 1;
    IF EXISTS (
        SELECT 1 FROM dbo.OrderDetails d JOIN (SELECT DISTINCT OrderDetailId FROM inserted) a ON a.OrderDetailId = d.OrderDetailId
        WHERE d.Quantity < (SELECT COUNT(*) FROM dbo.OrderDetailSerials x WHERE x.OrderDetailId = d.OrderDetailId)
    ) THROW 50112, N'Số serial vượt số lượng dòng đơn.', 1;
    IF EXISTS (
        SELECT 1 FROM deleted d JOIN dbo.Warranties w ON w.OrderDetailId = d.OrderDetailId AND w.SerialId = d.SerialId
        WHERE w.Status = 'Active'
    ) THROW 50113, N'Phải vô hiệu bảo hành trước khi nhả liên kết serial.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_Warranties_Integrity
ON dbo.Warranties AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT WarrantyId, SerialId, OrderDetailId, CustomerId, CoveredQuantity FROM deleted
        EXCEPT SELECT WarrantyId, SerialId, OrderDetailId, CustomerId, CoveredQuantity FROM inserted
    ) THROW 50114, N'Không xoá hoặc đổi chủ thể bảo hành; hãy vô hiệu bản ghi.', 1;
    IF EXISTS (
        SELECT 1 FROM inserted i
        JOIN dbo.OrderDetails d ON d.OrderDetailId = i.OrderDetailId
        JOIN dbo.Orders o WITH (UPDLOCK, HOLDLOCK) ON o.OrderId = d.OrderId
        LEFT JOIN dbo.ProductSerials s ON s.SerialId = i.SerialId
        WHERE i.CustomerId <> o.CustomerId
           OR (d.IsSerialTrackedSnapshot = 0 AND (i.SerialId IS NOT NULL OR i.CoveredQuantity <> d.Quantity))
           OR (d.IsSerialTrackedSnapshot = 1 AND (i.SerialId IS NULL OR s.ProductId <> d.ProductId OR i.CoveredQuantity <> 1))
           OR (i.Status = 'Active' AND o.Status = 'Cancelled')
           OR (i.Status = 'Active' AND i.SerialId IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM dbo.OrderDetailSerials ods WHERE ods.OrderDetailId = i.OrderDetailId AND ods.SerialId = i.SerialId))
    ) THROW 50115, N'Bảo hành không khớp khách hàng, sản phẩm, serial hoặc số lượng của đơn.', 1;
END
GO

CREATE OR ALTER TRIGGER dbo.tr_Invoices_Snapshot
ON dbo.Invoices AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT InvoiceId, InvoiceNo, OrderId, IssuedByEmployee, BuyerName, BuyerCompany, BuyerTaxCode,
               BuyerAddress, SubtotalAmount, DiscountAmount, VatAmount, TotalAmount FROM deleted
        EXCEPT
        SELECT InvoiceId, InvoiceNo, OrderId, IssuedByEmployee, BuyerName, BuyerCompany, BuyerTaxCode,
               BuyerAddress, SubtotalAmount, DiscountAmount, VatAmount, TotalAmount FROM inserted
    ) THROW 50116, N'Không sửa/xoá nội dung hoá đơn đã phát hành; hãy vô hiệu hoá đơn.', 1;
    IF EXISTS (
        SELECT i.OrderId, i.BuyerName, i.BuyerCompany, i.BuyerTaxCode, i.BuyerAddress,
               i.SubtotalAmount, i.DiscountAmount, i.VatAmount, i.TotalAmount
        FROM inserted i WHERE NOT EXISTS (SELECT 1 FROM deleted d WHERE d.InvoiceId = i.InvoiceId)
        EXCEPT
        SELECT o.OrderId, o.BillingName, o.BillingCompany, o.BillingTaxCode, o.BillingAddress,
               o.Subtotal, o.DiscountAmount, o.VatAmount, o.TotalAmount FROM dbo.Orders o
    ) THROW 50117, N'Nội dung hoá đơn không khớp thông tin đã chốt trên đơn.', 1;
END
GO

-- In lại chứng từ bằng snapshot, không phụ thuộc tên/SKU hiện tại trong Products.
CREATE OR ALTER VIEW dbo.vw_InvoiceLines
AS
SELECT i.InvoiceId, i.InvoiceNo, i.Status AS InvoiceStatus, d.OrderDetailId, d.ProductId,
       d.SkuSnapshot AS Sku, d.ProductNameSnapshot AS ProductName,
       d.Quantity, d.UnitPrice, d.LineTotal, d.WarrantyMonths
FROM dbo.Invoices i JOIN dbo.OrderDetails d ON d.OrderId = i.OrderId;
GO

CREATE OR ALTER TRIGGER dbo.tr_Products_SerialMode
ON dbo.Products AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM inserted i JOIN deleted d ON d.ProductId=i.ProductId
        WHERE i.IsSerialTracked<>d.IsSerialTracked AND
             (d.QtyOnHand<>0 OR d.QtyReserved<>0
              OR EXISTS (SELECT 1 FROM dbo.ProductSerials s WHERE s.ProductId=i.ProductId)
              OR EXISTS (SELECT 1 FROM dbo.OrderDetails od WHERE od.ProductId=i.ProductId)
              OR EXISTS (SELECT 1 FROM dbo.GoodsReceiptDetails gd WHERE gd.ProductId=i.ProductId))
    ) THROW 50119,N'Không đổi chế độ serial của sản phẩm đã có tồn hoặc chứng từ.',1;
END
GO
