model gpt-4
stream true
temperature 0.7
max_tokens 2048
tools*
    type function
    function
        name echo
        description Echo back the input
        parameters
            type object
            properties
                text
                    type string
            required*
                text
