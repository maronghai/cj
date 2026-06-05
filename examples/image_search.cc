model gpt-4o
tools*
    type function
    function
        name image_search
        description Search for images matching a query
        parameters
            type object
            properties
                query
                    type string
                    description Search query
                size
                    type string
                    description Image dimensions
                    enum*
                        small
                        medium
                        large
                num_results
                    type integer
                    description How many images to return
            required*
                query
                size
