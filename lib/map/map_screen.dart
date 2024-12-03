import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class MapScreen extends StatefulWidget {
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _controller = Completer<GoogleMapController>();
  Position? _currentPosition;
  Set<Marker> _markers = {};
  String? _selectedCategory;
  bool _isSearchVisible = false;
  TextEditingController _searchController = TextEditingController();
  String _currentSearchText = "";
  List<String> _searchHistory = [];
  Map<String, dynamic>? _selectedRestaurant;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _determinePosition();
    _fetchRestaurants();
  }

  Future<void> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('위치 서비스를 활성화해주세요.')),
      );
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('위치 권한이 필요합니다.')),
        );
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('위치 권한이 영구적으로 거부되었습니다. 설정에서 권한을 활성화해주세요.')),
      );
      return;
    }

    final position = await Geolocator.getCurrentPosition();
    setState(() {
      _currentPosition = position;
      _addCurrentLocationMarker(position);
    });
  }

  void _addCurrentLocationMarker(Position position) {
    _markers.add(
      Marker(
        markerId: MarkerId('current_location'),
        position: LatLng(position.latitude, position.longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        infoWindow: InfoWindow(title: '현재 위치'),
      ),
    );
  }

  Future<void> _fetchBookmarks() async {
    try {
      // FirebaseAuth에서 현재 로그인한 사용자의 이메일 가져오기
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('로그인한 사용자가 없습니다.')),
        );
        return;
      }

      final String userEmail = user.email ?? '';
      print('현재 사용자 이메일: $userEmail');
      if (userEmail.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('이메일을 가져올 수 없습니다.')),
        );
        return;
      }

      // Firestore에서 북마크 데이터를 가져오기
      final DocumentSnapshot userDoc = await FirebaseFirestore.instance
          .collection('BookMarks')
          .doc(userEmail)
          .get();

      if (!userDoc.exists) {
        print('사용자 북마크 문서를 찾을 수 없음: $userEmail');
      } else {
        print('북마크 데이터: ${userDoc.data()}');
      }

      if (!userDoc.exists || userDoc.data() == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('북마크 데이터를 찾을 수 없습니다.')),
        );
        return;
      }

      // 북마크 데이터를 읽어옴
      final List<dynamic> bookmarks = (userDoc.data() as Map<String, dynamic>)['bookMarks'] ?? [];

      List<Marker> bookmarkMarkers = [];
      for (var bookmark in bookmarks) {
        final String name = bookmark['name'] ?? '';

        // `Restaurants` 컬렉션에서 이름으로 검색
        final QuerySnapshot restaurantSnapshot = await FirebaseFirestore.instance
            .collection('Restaurants')
            .where('name', isEqualTo: name)
            .get();

        if (restaurantSnapshot.docs.isEmpty) {
          print('식당을 찾을 수 없음: $name');
          continue;
        }

        // 첫 번째 검색 결과 사용
        final restaurantData = restaurantSnapshot.docs.first.data() as Map<String, dynamic>;
        final GeoPoint location = restaurantData['location'];
        final String category = restaurantData['category'] ?? '카테고리 없음';
        final String address = restaurantData['address'] ?? '주소 없음';
        final String openTime = restaurantData['openTime'] ?? '영업시간 없음';

        // 마커 추가
        bookmarkMarkers.add(
          Marker(
            markerId: MarkerId(name),
            position: LatLng(location.latitude, location.longitude),
            infoWindow: InfoWindow(
              title: name,
              snippet: '$category\n$address\n영업시간: $openTime',
            ),
          ),
        );
      }

      // 마커를 상태로 업데이트
      setState(() {
        _markers = bookmarkMarkers.toSet();
      });
    } catch (e) {
      print('북마크 데이터를 가져오는 중 에러 발생: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('북마크 데이터를 불러오는 데 실패했습니다.')),
      );
    }
  }


  Future<void> _fetchRestaurants() async {
    try {
      final QuerySnapshot snapshot = await FirebaseFirestore.instance.collection('Restaurants').get();

      List<Marker> tempMarkers = [];
      LatLng? closestPosition;
      double closestDistance = double.infinity;

      setState(() {
        _markers.removeWhere((marker) => marker.markerId.value != 'current_location');

        for (var doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;
          final String name = data['name'] ?? '';
          final String category = data['category'] ?? '';
          final String address = data['address'] ?? '주소 정보 없음';
          final String openTime = data['openTime'] ?? '영업시간 정보 없음';
          final String imageUrl = data['imageUrl'] ?? '';
          final GeoPoint geoPoint = data['location'];

          if (_selectedCategory != null && _selectedCategory != '북마크') {
            if (category != _selectedCategory) continue;
          }

          if (_currentSearchText.isNotEmpty) {
            if (!name.contains(_currentSearchText) && !category.contains(_currentSearchText)) {
              continue;
            }
          }

          final restaurantPosition = LatLng(geoPoint.latitude, geoPoint.longitude);

          if (_currentPosition != null) {
            final distance = Geolocator.distanceBetween(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
              geoPoint.latitude,
              geoPoint.longitude,
            );

            if (distance < closestDistance) {
              closestDistance = distance;
              closestPosition = restaurantPosition;
            }
          }

          BitmapDescriptor markerIcon;
          if (category == '한식') {
            markerIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
          } else if (category == '중식') {
            markerIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
          } else if (category == '양식') {
            markerIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
          } else {
            markerIcon = BitmapDescriptor.defaultMarker;
          }

          tempMarkers.add(
            Marker(
              markerId: MarkerId(name),
              position: restaurantPosition,
              icon: markerIcon,
              infoWindow: InfoWindow(
                title: name,
                snippet: category,
              ),
              onTap: () {
                _onMarkerTapped(
                  name,
                  address,
                  openTime,
                  data['imageUrl'] ?? '',
                  category,
                );
              },
            ),
          );
        }

        _markers = tempMarkers.toSet();
      });

      if (closestPosition != null) {
        final GoogleMapController controller = await _controller.future;
        controller.animateCamera(CameraUpdate.newLatLngZoom(closestPosition!, 16));
      }
    } catch (e) {
      print('Firestore 에러: $e');
    }
  }

  void _onMarkerTapped(String name, String address, String openTime, String imageUrl, String category) {
    setState(() {
      _selectedRestaurant = {
        'name': name,
        'address': address,
        'openTime': openTime,
        'imageUrl': imageUrl,
        'category': category,
      };
    });
  }

  Widget _buildCategoryButton(String label, IconData icon, Color color) {
    final isSelected = _selectedCategory == label;
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_selectedCategory == label) {
            _selectedCategory = null; // 이미 선택된 경우 해제
          } else {
            _selectedCategory = label; // 새 카테고리 선택
          }
        });

        // 북마크 버튼 클릭 시 북마크 데이터 불러오기
        if (label == '북마크') {
          _fetchBookmarks();
        } else {
          _fetchRestaurants();
        }
      },
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 10),
        padding: EdgeInsets.symmetric(vertical: 6, horizontal: 11.3),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.white : color),
            SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchOverlay() {
    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back),
                  onPressed: () {
                    setState(() {
                      _isSearchVisible = false;
                    });
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '검색어를 입력하세요.',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (value) {
                      setState(() {
                        if (!_searchHistory.contains(value)) {
                          _searchHistory.add(value);
                        }
                        _currentSearchText = value;
                        _isSearchVisible = false;
                        _fetchRestaurants();
                      });
                    },
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _currentSearchText = "";
                      _fetchRestaurants();
                    });
                  },
                ),
              ],
            ),
            if (_searchHistory.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _searchHistory.clear();
                      });
                    },
                    child: Text(
                      '기록 삭제',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _searchHistory.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(_searchHistory[index]),
                    onTap: () {
                      _searchController.text = _searchHistory[index];
                      setState(() {
                        _currentSearchText = _searchHistory[index];
                        _isSearchVisible = false;
                        _fetchRestaurants();
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRestaurantInfo() {
    if (_selectedRestaurant == null) return SizedBox.shrink();

    return Positioned(
      bottom: 20,
      left: 10,
      right: 60, // 가로 크기를 조정하여 오른쪽 여백 추가
      child: Container(
        padding: EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [
            BoxShadow(color: Colors.black26, blurRadius: 4.0, offset: Offset(0, 2)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selectedRestaurant!['imageUrl'] != null &&
                _selectedRestaurant!['imageUrl'].isNotEmpty)
              Container(
                width: double.infinity,
                height: 120, // 이미지 크기를 적절히 줄임
                margin: EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  image: DecorationImage(
                    image: NetworkImage(_selectedRestaurant!['imageUrl']),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Text(
              _selectedRestaurant!['name'],
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 5),
            Text('주소: ${_selectedRestaurant!['address']}'),
            SizedBox(height: 5),
            Text('영업시간: ${_selectedRestaurant!['openTime']}'),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: Icon(Icons.close, color: Colors.grey),
                onPressed: () {
                  setState(() {
                    _selectedRestaurant = null; // 정보 닫기
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _currentPosition == null
              ? Center(child: CircularProgressIndicator())
              : GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: CameraPosition(
              target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
              zoom: 14.0,
            ),
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            mapToolbarEnabled: false,
            markers: _markers,
            onMapCreated: (GoogleMapController controller) {
              _controller.complete(controller);
            },
          ),
          if (_isSearchVisible)
            Positioned.fill(
              child: _buildSearchOverlay(),
            ),
          if (!_isSearchVisible)
            Positioned(
              top: 45,
              left: 10,
              right: 10,
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isSearchVisible = true;
                      });
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 10.0, vertical: 12.0),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: [
                          BoxShadow(color: Colors.black26, blurRadius: 4.0, offset: Offset(0, 2)),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search, color: Colors.black),
                          SizedBox(width: 8),
                          Text(
                            _currentSearchText.isEmpty ? '검색' : _currentSearchText,
                            style: TextStyle(color: _currentSearchText.isEmpty ? Colors.grey : Colors.black),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildCategoryButton('북마크', Icons.bookmark, Colors.blue),
                        _buildCategoryButton('한식', Icons.rice_bowl, Colors.green),
                        _buildCategoryButton('중식', Icons.ramen_dining, Colors.red),
                        _buildCategoryButton('양식', Icons.dinner_dining, Colors.orange),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          _buildRestaurantInfo(),
        ],
      ),
    );
  }
}
