:ON ERROR EXIT
-- Run on a disposable seeded database after 01 -> 02 -> 03, or after migration 004.
-- Positive and negative cases roll back their own transactions. Sequence values may advance.
USE LaptopShopDB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Exercise actual procedures, not hand-built copies of their logic.
BEGIN TRY
    BEGIN TRAN;
    DECLARE @customer INT=(SELECT CustomerId FROM dbo.Customers WHERE Phone='0912000001');
    DECLARE @employeeAccount INT=(SELECT AccountId FROM dbo.Employees WHERE EmployeeCode='NV001');
    DECLARE @cart INT=(SELECT CartId FROM dbo.Carts WHERE CustomerId=@customer);
    DECLARE @address INT, @order INT, @product INT=(SELECT ProductId FROM dbo.Products WHERE Sku='LOGI-G102');
    IF @customer IS NULL OR @employeeAccount IS NULL OR @product IS NULL
        THROW 50300, N'Test cần dữ liệu mẫu 03_seed.sql.', 1;
    IF @cart IS NULL BEGIN
        INSERT dbo.Carts(CustomerId) VALUES(@customer);
        SET @cart=SCOPE_IDENTITY();
    END;
    DELETE dbo.CartItems WHERE CartId=@cart;
    INSERT dbo.CartItems(CartId,ProductId,Quantity) VALUES(@cart,@product,2);
    INSERT dbo.CustomerAddresses(CustomerId,ReceiverName,ReceiverPhone,AddressLine,Ward,District,Province)
    VALUES(@customer,N'Người nhận khác người mua','0900000000',REPLICATE(N'A',200),REPLICATE(N'B',100),REPLICATE(N'C',100),REPLICATE(N'D',100));
    SET @address=SCOPE_IDENTITY();
    DECLARE @onhand INT=(SELECT QtyOnHand FROM dbo.Products WHERE ProductId=@product);
    DECLARE @reserved INT=(SELECT QtyReserved FROM dbo.Products WHERE ProductId=@product);
    EXEC dbo.sp_PlaceOrderFromCart @CustomerId=@customer,@AddressId=@address,@PaymentMethod='COD',@OrderId=@order OUTPUT,
         @BillingName=N'Người mua thử nghiệm',@BillingCompany=N'Công ty lúc đặt',@BillingTaxCode='TEST004',
         @BillingAddress=N'Địa chỉ xuất hoá đơn riêng',@UseCustomerBilling=0;
    IF (SELECT LEN(ShippingAddress) FROM dbo.Orders WHERE OrderId=@order)<>506
        THROW 50301, N'Địa chỉ bị cắt.', 1;
    UPDATE dbo.Customers SET CompanyName=N'Đã đổi sau khi đặt',TaxCode='CHANGED' WHERE CustomerId=@customer;
    UPDATE dbo.Products SET ProductName=N'Đổi tên sau khi đặt',Sku='TEST-RENAMED-004' WHERE ProductId=@product;
    EXEC dbo.sp_ApproveOrder @OrderId=@order,@AccountId=@employeeAccount;
    IF NOT EXISTS (SELECT 1 FROM dbo.Invoices WHERE OrderId=@order AND BuyerName=N'Người mua thử nghiệm'
                   AND BuyerCompany=N'Công ty lúc đặt' AND BuyerTaxCode='TEST004' AND BuyerAddress=N'Địa chỉ xuất hoá đơn riêng')
        THROW 50302, N'Hoá đơn không giữ thông tin đặt hàng.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.vw_InvoiceLines l JOIN dbo.Invoices i ON i.InvoiceId=l.InvoiceId
                   WHERE i.OrderId=@order AND l.Sku='LOGI-G102' AND l.ProductName<>N'Đổi tên sau khi đặt')
        THROW 50303, N'Tên/SKU chứng từ thay đổi theo danh mục.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.vw_WarrantyLookup WHERE OrderId=@order AND SerialId IS NULL
                   AND CoveredQuantity=2 AND Status='Active')
        THROW 50304, N'Thiếu bảo hành hàng không serial.', 1;
    EXEC dbo.sp_CancelOrder @OrderId=@order,@Reason=N'Test rollback',@AccountId=@employeeAccount;
    IF EXISTS (SELECT 1 FROM dbo.vw_WarrantyLookup WHERE OrderId=@order AND Status<>'Voided')
        THROW 50305, N'Huỷ đơn chưa vô hiệu bảo hành phụ kiện.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Products WHERE ProductId=@product AND (QtyOnHand<>@onhand OR QtyReserved<>@reserved))
        THROW 50306, N'Tồn kho không được hoàn lại.', 1;
    ROLLBACK TRAN;
    PRINT N'PASS: địa chỉ dài, billing snapshot, sản phẩm snapshot, bảo hành phụ kiện, huỷ/trả tồn.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    THROW;
END CATCH;
GO

-- Serial product lifecycle, including releasing and selling the same serial again.
BEGIN TRY
    BEGIN TRAN;
    DECLARE @customer INT=(SELECT CustomerId FROM dbo.Customers WHERE Phone='0912000001');
    DECLARE @cart INT=(SELECT CartId FROM dbo.Carts WHERE CustomerId=@customer);
    DECLARE @address INT=(SELECT TOP 1 AddressId FROM dbo.CustomerAddresses WHERE CustomerId=@customer ORDER BY AddressId);
    DECLARE @actor INT=(SELECT AccountId FROM dbo.Employees WHERE EmployeeCode='NV001');
    DECLARE @product INT=(SELECT ProductId FROM dbo.Products WHERE Sku='ASUS-TUF-F15');
    DECLARE @first INT,@second INT,@serial BIGINT;
    DELETE dbo.CartItems WHERE CartId=@cart;
    INSERT dbo.CartItems(CartId,ProductId,Quantity) VALUES(@cart,@product,1);
    EXEC dbo.sp_PlaceOrderFromCart @CustomerId=@customer,@AddressId=@address,@PaymentMethod='COD',@OrderId=@first OUTPUT;
    EXEC dbo.sp_ApproveOrder @OrderId=@first,@AccountId=@actor;
    SELECT @serial=SerialId FROM dbo.vw_WarrantyLookup WHERE OrderId=@first;
    IF @serial IS NULL THROW 50307,N'Thiếu bảo hành serial.',1;
    EXEC dbo.sp_CancelOrder @OrderId=@first,@Reason=N'Test serial resale',@AccountId=@actor;
    INSERT dbo.CartItems(CartId,ProductId,Quantity) VALUES(@cart,@product,1);
    EXEC dbo.sp_PlaceOrderFromCart @CustomerId=@customer,@AddressId=@address,@PaymentMethod='COD',@OrderId=@second OUTPUT;
    EXEC dbo.sp_ApproveOrder @OrderId=@second,@AccountId=@actor;
    IF NOT EXISTS (SELECT 1 FROM dbo.vw_WarrantyLookup WHERE OrderId=@first AND SerialId=@serial AND Status='Voided')
       OR NOT EXISTS (SELECT 1 FROM dbo.vw_WarrantyLookup WHERE OrderId=@second AND SerialId=@serial AND Status='Active')
        THROW 50308,N'Không giữ được bảo hành cũ và bán lại serial sau huỷ.',1;
    ROLLBACK TRAN;
    PRINT N'PASS: bảo hành serial, huỷ và bán lại.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    THROW;
END CATCH;
GO

-- immutable order lines
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.OrderDetails SET Quantity=Quantity+1 WHERE OrderDetailId=(SELECT MIN(OrderDetailId) FROM dbo.OrderDetails);
    THROW 50399, N'FAIL: expected rejection: immutable order lines', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50101 THROW;
    PRINT N'PASS: immutable order lines';
END CATCH;
GO

-- immutable order totals
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.Orders SET Subtotal=Subtotal+100 WHERE OrderId=(SELECT MIN(OrderId) FROM dbo.Orders);
    THROW 50399, N'FAIL: expected rejection: immutable order totals', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50104 THROW;
    PRINT N'PASS: immutable order totals';
END CATCH;
GO

-- posted receipt lines
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.GoodsReceiptDetails SET Quantity=Quantity+1 WHERE ReceiptDetailId=(SELECT MIN(d.ReceiptDetailId) FROM dbo.GoodsReceiptDetails d JOIN dbo.GoodsReceipts g ON g.ReceiptId=d.ReceiptId WHERE g.Status='Posted');
    THROW 50399, N'FAIL: expected rejection: posted receipt lines', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50105 THROW;
    PRINT N'PASS: posted receipt lines';
END CATCH;
GO

-- posted receipt header
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.GoodsReceipts SET TotalAmount=TotalAmount+100 WHERE ReceiptId=(SELECT MIN(ReceiptId) FROM dbo.GoodsReceipts WHERE Status='Posted');
    THROW 50399, N'FAIL: expected rejection: posted receipt header', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50107 THROW;
    PRINT N'PASS: posted receipt header';
END CATCH;
GO

-- serial wrong product
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.ProductSerials SET ProductId=(SELECT ProductId FROM dbo.Products WHERE Sku='MSI-KATANA-15') WHERE SerialId=(SELECT MIN(SerialId) FROM dbo.ProductSerials WHERE ProductId=(SELECT ProductId FROM dbo.Products WHERE Sku='ASUS-TUF-F15'));
    THROW 50399, N'FAIL: expected rejection: serial wrong product', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50108 THROW;
    PRINT N'PASS: serial wrong product';
END CATCH;
GO

-- warranty wrong customer
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.Warranties SET CustomerId=(SELECT MAX(CustomerId) FROM dbo.Customers) WHERE WarrantyId=(SELECT MIN(WarrantyId) FROM dbo.Warranties);
    THROW 50399, N'FAIL: expected rejection: warranty wrong customer', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50114 THROW;
    PRINT N'PASS: warranty wrong customer';
END CATCH;
GO

-- immutable invoice
BEGIN TRY
    BEGIN TRAN;
    UPDATE dbo.Invoices SET BuyerName=N'Changed' WHERE InvoiceId=(SELECT MIN(InvoiceId) FROM dbo.Invoices);
    THROW 50399, N'FAIL: expected rejection: immutable invoice', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50116 THROW;
    PRINT N'PASS: immutable invoice';
END CATCH;
GO

-- serial wrong order product
BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.OrderDetailSerials(OrderDetailId,SerialId) SELECT TOP 1 d.OrderDetailId,s.SerialId FROM dbo.OrderDetails d JOIN dbo.Orders o ON o.OrderId=d.OrderId CROSS JOIN dbo.ProductSerials s WHERE o.Status='Pending' AND d.ProductId<>s.ProductId AND s.Status='InStock' AND NOT EXISTS(SELECT 1 FROM dbo.OrderDetailSerials x WHERE x.SerialId=s.SerialId);
    THROW 50399, N'FAIL: expected rejection: serial wrong order product', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER()<>50111 THROW;
    PRINT N'PASS: serial wrong order product';
END CATCH;
GO

-- duplicate active serial link
BEGIN TRY
    BEGIN TRAN;
    INSERT dbo.OrderDetailSerials(OrderDetailId,SerialId) SELECT TOP 1 d.OrderDetailId,x.SerialId FROM dbo.OrderDetailSerials x CROSS JOIN dbo.OrderDetails d WHERE d.OrderDetailId<>x.OrderDetailId;
    THROW 50399, N'FAIL: expected rejection: duplicate active serial link', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRAN;
    IF ERROR_NUMBER() NOT IN (2601,2627) THROW;
    PRINT N'PASS: duplicate active serial link';
END CATCH;
GO
