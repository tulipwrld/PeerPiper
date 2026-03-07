import socket
import threading
import json
import time

def announce_presence(node_id, username, port=5000, broadcast_port=5001):
    """
    Функция для объявления о своем присутствии в локальной сети
    
    Args:
        node_id: уникальный идентификатор узла
        username: имя пользователя
        port: порт для приема сообщений
        broadcast_port: порт для broadcast объявлений
    """
    
    # Создаем сокет для broadcast
    broadcast_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    broadcast_socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    
    # Формируем объявление
    announcement = {
        'node_id': node_id,
        'username': username,
        'port': port,
        'timestamp': time.time()
    }
    
    try:
        # Отправляем broadcast сообщение
        broadcast_socket.sendto(
            json.dumps(announcement).encode('utf-8'),
            ('<broadcast>', broadcast_port)
        )
        print(f"Объявление отправлено: {username} в сети")
        
    except Exception as e:
        print(f"Ошибка при отправке объявления: {e}")
    
    finally:
        broadcast_socket.close()


# Функция для прослушивания объявлений других
def listen_for_announcements(broadcast_port=5001, callback=None):
    """
    Слушает объявления других узлов в сети
    
    Args:
        broadcast_port: порт для прослушивания
        callback: функция, вызываемая при получении объявления
    """
    
    # Создаем сокет для прослушивания
    listen_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listen_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listen_socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    
    try:
        listen_socket.bind(('', broadcast_port))
        print(f"Слушаю объявления на порту {broadcast_port}")
        
        while True:
            data, addr = listen_socket.recvfrom(1024)
            announcement = json.loads(data.decode('utf-8'))
            
            # Вызываем callback функцию с полученными данными
            if callback:
                callback(announcement, addr[0])
                
    except KeyboardInterrupt:
        print("\nПрослушивание остановлено")
    finally:
        listen_socket.close()


# Пример использования
if __name__ == "__main__":
    import uuid
    
    # Генерируем уникальный ID для этого узла
    node_id = str(uuid.uuid4())[:8]
    username = "TestUser"
    
    # Функция обратного вызова для обработки полученных объявлений
    def on_announcement_received(announcement, ip):
        print(f"Обнаружен узел: {announcement['username']}@{announcement['node_id']} ({ip}:{announcement['port']})")
    
    # Запускаем прослушивание в отдельном потоке
    listener_thread = threading.Thread(
        target=listen_for_announcements,
        args=(5001, on_announcement_received),
        daemon=True
    )
    listener_thread.start()
    
    # Периодически отправляем объявления
    try:
        while True:
            announce_presence(node_id, username)
            time.sleep(5)  # Объявляем каждые 5 секунд
    except KeyboardInterrupt:
        print("\nПрограмма завершена")