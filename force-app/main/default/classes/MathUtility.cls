public with sharing class MathUtility {
    // Returns the sum of two integers.
    public static Integer add(Integer a, Integer b) {
        Integer left = a != null ? a : 0;
        Integer right = b != null ? b : 0;
        return left + right;
    }

    // Returns true when the given number is even.
    public static Boolean isEven(Integer value) {
        return value != null && Math.mod(value, 2) == 0;
    }
}
  