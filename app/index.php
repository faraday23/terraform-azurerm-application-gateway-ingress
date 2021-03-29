<h1>Hello World</h1>
<?php

echo "<strong>Remote Port:</strong> " . $_SERVER['REMOTE_PORT'] . "<br />";
echo "<strong>Local Port:</strong> " . $_SERVER['SERVER_PORT'] . "<br />";
echo "<strong>Name:</strong> " . $_SERVER['SERVER_NAME'] . "<br />";
echo "<strong>Address:</strong> " . $_SERVER['SERVER_ADDR'] . "<br />";
echo "<strong>Protocol:</strong> " . $_SERVER['SERVER_PROTOCOL'] . "<br />";
echo "<strong>Method:</strong> " . $_SERVER['REQUEST_METHOD'] . "<br />";
echo "<strong>URI:</strong> " . $_SERVER['REQUEST_URI'] . "<br />";
echo "<strong>Host:</strong> " . $_SERVER['HTTP_HOST'] . "<br />";
