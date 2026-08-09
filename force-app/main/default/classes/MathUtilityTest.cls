@IsTest
private class MathUtilityTest {

    // Covers add() with two non-null integers.
    @IsTest
    static void add_sumsTwoValues() {
        Test.startTest();
        Integer result = MathUtility.add(2, 3);
        Test.stopTest();

        System.assertEquals(5, result, '2 + 3 should be 5');
    }

    // Covers the null-guard paths in add(): nulls are treated as 0.
    @IsTest
    static void add_treatsNullsAsZero() {
        Test.startTest();
        Integer result = MathUtility.add(null, null);
        Test.stopTest();

        System.assertEquals(0, result, 'null + null should be 0');
    }

    // Covers isEven() for an even, an odd, and a null value.
    @IsTest
    static void isEven_evaluatesCorrectly() {
        Test.startTest();
        Boolean evenCase = MathUtility.isEven(4);
        Boolean oddCase = MathUtility.isEven(5);
        Boolean nullCase = MathUtility.isEven(null);
        Test.stopTest();

        System.assertEquals(true, evenCase, '4 should be even');
        System.assertEquals(false, oddCase, '5 should not be even');
        System.assertEquals(false, nullCase, 'null should not be even');
    }
}
