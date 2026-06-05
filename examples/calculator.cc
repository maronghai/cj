# calculator — three params, op described as enum-ish string
model gpt-4o-mini
tools*
    type function
    function
        name calculator
        description Perform basic arithmetic on two numbers
        parameters
            type object
            properties
                a
                    type number
                    description First operand
                b
                    type number
                    description Second operand
                op
                    type string
                    description "One of: add, sub, mul, div"
            required*
                a
                b
                op
