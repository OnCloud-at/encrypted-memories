/// Truncates toward zero, then checks representation and integer multiplication.
/// Callers apply any required floating-point rounding or scaling before conversion.
package func checkedInteger<Integer: FixedWidthInteger>(
    _ value: Double, as _: Integer.Type, multipliedBy multiplier: Integer = 1
) -> Integer? {
    guard let integer = Integer(exactly: value.rounded(.towardZero)) else { return nil }
    let (scaled, overflow) = integer.multipliedReportingOverflow(by: multiplier)
    return overflow ? nil : scaled
}
