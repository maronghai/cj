# get_weather — single string param with quoted description
model gpt-4o-mini
tools*
    type function
    function
        name get_weather
        description Get current weather for a location
        parameters
            type object
            properties
                location
                    type string
                    description "City and state, e.g. San Francisco, CA"
            required*
                location
