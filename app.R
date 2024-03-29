library(shiny)
library(keras)

# Adapted from https://keras.rstudio.com/articles/examples/deep_dream.html

# Utility functions -------------------------------------------------------

# Util function to open, resize, and format pictures into tensors that Inception V3 can process
preprocess_image <- function(image_path) {
  image_load(image_path) %>%
    image_to_array() %>%
    array_reshape(dim = c(1, dim(.))) %>%
    inception_v3_preprocess_input()
}

# Util function to convert a tensor into a valid image
deprocess_image <- function(img) {
  img <- array_reshape(img, dim = c(dim(img)[[2]], dim(img)[[3]], 3))
  # Undoes preprocessing that was performed by `imagenet_preprocess_input`
  img <- img / 2
  img <- img + 0.5
  img <- img * 255
  
  dims <- dim(img)
  img <- pmax(0, pmin(img, 255))
  dim(img) <- dims
  img
}

resize_img <- function(img, size) {
  image_array_resize(img, size[[1]], size[[2]])
}

save_img <- function(img, fname) {
  img <- deprocess_image(img)
  image_array_save(img, fname)
}


# Model  ----------------------------------------------

# You won't be training the model, so this command disables all training-specific operations.
k_set_learning_phase(0)

# Builds the Inception V3 network, without its convolutional base. The model will be loaded with pretrained ImageNet weights.
model <- application_inception_v3(weights = "imagenet",
                                  include_top = FALSE)


# Named list mapping layer names to a coefficient quantifying how much the layer's activation contributes to the loss you'll seek to maximize. Note that the layer names are hardcoded in the built-in Inception V3 application. You can list all layer names using `summary(model)`.
layer_contributions <- list(
  #mixed2 = 0.2,
  #mixed3 = 3,
  #mixed4 = 2,
  mixed5 = 1.5
)

# You'll define the loss by adding layer contributions to this scalar variable
loss <- k_variable(0)
for (layer_name in names(layer_contributions)) {
  coeff <- layer_contributions[[layer_name]]
  # Retrieves the layer's output
  activation <- get_layer(model, layer_name)$output
  scaling <- k_prod(k_cast(k_shape(activation), "float32"))
  # Retrieves the layer's output
  loss <- loss + (coeff * k_sum(k_square(activation)) / scaling)
}

# Retrieves the layer's output
dream <- model$input

# Computes the gradients of the dream with regard to the loss
grads <- k_gradients(loss, dream)[[1]]

# Normalizes the gradients (important trick)
grads <- grads / k_maximum(k_mean(k_abs(grads)), 1e-7)

outputs <- list(loss, grads)

# Sets up a Keras function to retrieve the value of the loss and gradients, given an input image
fetch_loss_and_grads <- k_function(list(dream), outputs)

eval_loss_and_grads <- function(x) {
  outs <- fetch_loss_and_grads(list(x))
  loss_value <- outs[[1]]
  grad_values <- outs[[2]]
  list(loss_value, grad_values)
}


# Run gradient ascent -----------------------------------------------------

# This function runs gradient ascent for a number of iterations.
gradient_ascent <-
  function(x, iterations, step, max_loss = NULL) {
    for (i in 1:iterations) {
      c(loss_value, grad_values) %<-% eval_loss_and_grads(x)
      if (!is.null(max_loss) && loss_value > max_loss)
        break
      cat("...Loss value at", i, ":", loss_value, "\n")
      x <- x + (step * grad_values)
    }
    x
  }

#get list of images in the images folder
images <- list.files("images")


# Define UI for application that draws a histogram
ui <- fluidPage(
  
  titlePanel("Deep Dream Shiny"),
  
  fluidRow(
    column(2,
    
             selectInput("source_img", "Image:",
                         images),
             sliderInput("step", "Gradient ascent step size", min = 0.01, max = 0.05, value = 0.02, step = 0.01),
             sliderInput("num_octave", "Number of scales at which to run gradient ascent", min = 1, max = 5, value = 3),
             sliderInput("octave_scale", "Size ratio between scales", min = 1.0, max = 1.8, value = 1.4, step = 0.1),
             sliderInput("iterations", "Number of ascent steps to run at each scale", min = 1, max = 10, value = 5),
             submitButton("Submit Changes to Dream", icon("clouds"))
           ),
    column(5,
           h4("Original Image"),
           plotOutput("plot1", width = "100%")
    ),
    column(5,
           h4("Dream Image"),
           plotOutput("plot2", width = "100%")
    )
  ))


# Define server logic required to draw a histogram
server <- function(input, output) {
  
  # A plot of fixed size
  output$plot1 <- renderImage({
    
    # Fill this with the path to the image you want to use.
    base_image_path <- paste("images/", input$source_img, sep = "")
    
    # Loads the base image into an array
    img <-
      preprocess_image(base_image_path)
    
    outfile <- tempfile(fileext='.png')
    
    # Generate a png
    png(outfile, width = 600, height = 600)
    par(mar = rep(0, 4))
    plot(as.raster(deprocess_image(img) / 255))
    dev.off()
    
    # Return a list
    list(src = outfile,
         alt = "This is alternate text")
  }, deleteFile = TRUE)
  
  # A plot of fixed size
  output$plot2 <- renderImage({
    
    
    # Playing with these hyperparameters will let you achieve new effects.
    # Gradient ascent step size
    step <- input$step
    # Number of scales at which to run gradient ascent
    num_octave <- input$num_octave
    # Size ratio between scales
    octave_scale <- input$octave_scale
    # Number of ascent steps to run at each scale
    iterations <- input$iterations
    # If the loss grows larger than 10, we will interrupt the gradient-ascent process to avoid ugly artifacts.
    max_loss <- 5
    
    # Fill this with the path to the image you want to use.
    base_image_path <- paste("images/", input$source_img, sep = "")
    
    # Loads the base image into an array
    img <-
      preprocess_image(base_image_path)
    
    # Prepares a list of shape tuples defining the different scales at which to run gradient ascent
    original_shape <- dim(img)[-1]
    successive_shapes <-
      list(original_shape)
    for (i in 1:num_octave) {
      shape <- as.integer(original_shape / (octave_scale ^ i))
      successive_shapes[[length(successive_shapes) + 1]] <-
        shape
    }
    # Reverses the list of shapes so they're in increasing order
    successive_shapes <-
      rev(successive_shapes)
    
    original_img <- img
    #  Resizes the array of the image to the smallest scale
    shrunk_original_img <-
      resize_img(img, successive_shapes[[1]])
    
    for (shape in successive_shapes) {
      cat("Processing image shape", shape, "\n")
      # Scales up the dream image
      img <- resize_img(img, shape)
      # Runs gradient ascent, altering the dream
      img <- gradient_ascent(img,
                             iterations = iterations,
                             step = step,
                             max_loss = max_loss)
      # Scales up the smaller version of the original image: it will be pixellated
      upscaled_shrunk_original_img <-
        resize_img(shrunk_original_img, shape)
      # Computes the high-quality version of the original image at this size
      same_size_original <-
        resize_img(original_img, shape)
      # The difference between the two is the detail that was lost when scaling up
      lost_detail <-
        same_size_original - upscaled_shrunk_original_img
      # Reinjects lost detail into the dream
      img <- img + lost_detail
      shrunk_original_img <-
        resize_img(original_img, shape)
      #save_img(img, fname = sprintf("deep_dream/dream_at_scale_%s.png",
      #                              paste(shape, collapse = "x")))
    }
    

    outfile <- tempfile(fileext='.png')
    
    # Generate a png
    png(outfile, width = 600, height = 600)
    par(mar = rep(0, 4))
    plot(as.raster(deprocess_image(img) / 255), xaxs="i", yaxs="i")
    dev.off()
    
    # Return a list
    list(src = outfile,
         alt = "This is alternate text")
  }, deleteFile = TRUE)
  
  
    #plot(as.raster(deprocess_image(img) / 255))
    #})
  
}

# Run the application 
shinyApp(ui = ui, server = server)

