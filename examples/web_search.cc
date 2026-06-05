# web_search — multiple params (string + integer)
model gpt-4o-mini
tools*
    type function
    function
        name web_search
        description Search the public web for a query
        parameters
            type object
            properties
                query
                    type string
                    description The search query
                num_results
                    type integer
                    description Number of results to return
            required*
                query
                num_results
