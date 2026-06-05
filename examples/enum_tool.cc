# enum_tool — uses enum+ for the JSON Schema "enum" array
model gpt-4o-mini
tools*
    type function
    function
        name set_unit
        description Set the temperature unit
        parameters
            type object
            properties
                unit
                    type string
                    description Temperature unit
                    enum+
                        celsius
                        fahrenheit
                        kelvin
            required*
                unit
